//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftDX open source project
//
// Copyright (c) 2026 SwiftDX Contributors
// Licensed under Apache License v2.0. See LICENSE for license information.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

/// A live `LISTEN`/`NOTIFY` subscription. It owns one dedicated connection parked
/// in a blocking receive loop on its own thread; each notification the server
/// delivers is yielded to ``notifications``. Iterate that stream to react to
/// changes. Ending the iteration (or calling ``close()``) closes the connection,
/// which unblocks the receive loop and finishes the stream.
public final class PostgresListener: @unchecked Sendable {

    private let connection: BlockingPostgresConnection
    public let notifications: AsyncThrowingStream<PostgresNotification, Error>

    init(connection: BlockingPostgresConnection, channels: [String]) throws(PostgresError) {
        self.connection = connection
        for channel in channels {
            try connection.listen(channel)
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PostgresNotification.self, throwing: Error.self)
        self.notifications = stream
        continuation.onTermination = { [connection] _ in connection.close() }
        let thread = Thread { [connection] in
            do {
                while true {
                    continuation.yield(try connection.awaitNotification())
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    public func close() {
        connection.close()
    }
}

extension Postgres {

    /// Opens a dedicated connection, subscribes it to `channels` with `LISTEN`, and
    /// returns a listener whose ``PostgresListener/notifications`` stream yields each
    /// notification. To watch a table, install a trigger that calls `pg_notify` on
    /// the channel (optionally with a `WHEN` filter) and listen on that channel.
    public static func listen(host: String, port: Int, username: String, password: String, database: String, applicationName: String, channels: [String]) throws(PostgresError) -> PostgresListener {
        let connection = try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        return try PostgresListener(connection: connection, channels: channels)
    }

    /// Subscribes to `channels` using the same connection settings as a pooled
    /// client, so a listener and a pool can share one `PostgresConfiguration`. A
    /// listener still opens its own dedicated connection, since it parks in a
    /// receive loop and cannot be borrowed from the pool.
    public static func listen(_ configuration: PostgresConfiguration, channels: [String]) throws(PostgresError) -> PostgresListener {
        try listen(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, channels: channels)
    }

    /// Watches `table` using a shared ``PostgresConfiguration``.
    public static func watchTable(_ configuration: PostgresConfiguration, table: String, channel: String) throws(PostgresError) -> PostgresListener {
        try watchTable(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, table: table, channel: channel)
    }

    /// Watches `table` for rows matching `filter`, using a shared ``PostgresConfiguration``.
    public static func watchTable(_ configuration: PostgresConfiguration, table: String, channel: String, where filter: String) throws(PostgresError) -> PostgresListener {
        try watchTable(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, table: table, channel: channel, where: filter)
    }

    /// Installs an AFTER INSERT/UPDATE/DELETE trigger on `table` that publishes each
    /// changed row as JSON (`{"op":…, "row":…}`) on `channel`, then returns a
    /// listener subscribed to that channel. Fires for every changed row.
    public static func watchTable(host: String, port: Int, username: String, password: String, database: String, applicationName: String, table: String, channel: String) throws(PostgresError) -> PostgresListener {
        try installChangeTrigger(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName, table: table, channel: channel, events: "INSERT OR UPDATE OR DELETE", whenClause: "")
    }

    /// As ``watchTable(host:port:username:password:database:applicationName:table:channel:)``
    /// but the trigger fires only for rows matching `filter`, a SQL boolean over the
    /// new row, for example `NEW.status = 'active'`. The filter runs in the server,
    /// so the client receives only matching changes.
    public static func watchTable(host: String, port: Int, username: String, password: String, database: String, applicationName: String, table: String, channel: String, where filter: String) throws(PostgresError) -> PostgresListener {
        try installChangeTrigger(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName, table: table, channel: channel, events: "INSERT OR UPDATE", whenClause: "WHEN (\(filter)) ")
    }

    private static func installChangeTrigger(host: String, port: Int, username: String, password: String, database: String, applicationName: String, table: String, channel: String, events: String, whenClause: String) throws(PostgresError) -> PostgresListener {
        let function = "dx_notify_\(channel)"
        let trigger = "dx_trg_\(channel)"
        let setup = try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        _ = try setup.execute("""
        CREATE OR REPLACE FUNCTION \(function)() RETURNS trigger LANGUAGE plpgsql AS $dx$
        BEGIN
          PERFORM pg_notify('\(channel)', json_build_object('op', TG_OP, 'row',
            CASE WHEN TG_OP = 'DELETE' THEN row_to_json(OLD) ELSE row_to_json(NEW) END)::text);
          RETURN COALESCE(NEW, OLD);
        END; $dx$
        """)
        _ = try setup.execute("DROP TRIGGER IF EXISTS \(trigger) ON \(table)")
        _ = try setup.execute("CREATE TRIGGER \(trigger) AFTER \(events) ON \(table) FOR EACH ROW \(whenClause)EXECUTE FUNCTION \(function)()")
        setup.close()
        let connection = try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        return try PostgresListener(connection: connection, channels: [channel])
    }
}
