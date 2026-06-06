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

import DXCore
import Foundation

/// A live `LISTEN`/`NOTIFY` subscription. It owns one dedicated connection driven
/// by a blocking receive loop on its own thread; each notification the server
/// delivers is yielded to ``notifications``. Iterate that stream to react to
/// changes. The loop also watches an interrupt pipe, so ``listen(_:)``,
/// ``unlisten(_:)`` and ``close()`` take effect immediately even while the read is
/// otherwise parked. Ending the iteration, calling ``close()``, or dropping the
/// listener stops the loop and closes the connection.
///
/// A subscription opened from a configuration heals itself: if its connection
/// drops, it reconnects in the background forever with capped backoff and re-issues
/// every active channel before resuming, so a server outage suspends delivery
/// rather than ending the subscription.
///
/// The stream buffers a bounded number of notifications. A consumer that falls
/// behind does not stall the server or grow memory without limit: once the buffer
/// is full the oldest pending notifications are dropped, matching the at-most-once
/// nature of `LISTEN`/`NOTIFY`.
public final class PostgresListener: @unchecked Sendable {

    private static let notificationBufferCapacity = 1024

    private let loop: SubscriptionReceiveLoop
    public let notifications: AsyncThrowingStream<PostgresNotification, Error>

    convenience init(connection: BlockingPostgresConnection, channels: [String]) throws(PostgresError) {
        try self.init(connection: connection, source: .fixed, channels: channels, permit: .unlimited())
    }

    convenience init(target: PostgresConnectionTarget, channels: [String]) throws(PostgresError) {
        try self.init(target: target, channels: channels, permit: .unlimited())
    }

    convenience init(target: PostgresConnectionTarget, channels: [String], permit: SubscriptionPermit) throws(PostgresError) {
        let connection = try target.connect()
        try self.init(connection: connection, source: .reconnectable(target), channels: channels, permit: permit)
    }

    init(connection: BlockingPostgresConnection, source: ListenerSource, channels: [String], permit: SubscriptionPermit) throws(PostgresError) {
        let control = try ListenerControl()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PostgresNotification.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(Self.notificationBufferCapacity))
        for channel in channels {
            try connection.listen(channel) { continuation.yield($0) }
        }
        let loop = SubscriptionReceiveLoop(connection: connection, source: source, control: control, continuation: continuation, channels: Set(channels), permit: permit)
        self.loop = loop
        self.notifications = stream
        continuation.onTermination = { [weak loop] _ in loop?.requestStop() }
        let thread = Thread { loop.run() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Adds `channel` to this subscription on its existing connection. Notifications
    /// on it begin flowing to ``notifications`` once the server acknowledges.
    public func listen(_ channel: String) {
        loop.listen(channel)
    }

    /// Stops delivering notifications for `channel` without affecting the others.
    public func unlisten(_ channel: String) {
        loop.unlisten(channel)
    }

    /// Stops the receive loop and closes the connection. Idempotent. Wakes the loop
    /// immediately even if it is parked in a blocking read.
    public func close() {
        loop.requestStop()
    }

    deinit {
        loop.requestStop()
    }
}

extension Postgres {

    /// Subscribes to `channels` and returns a listener whose
    /// ``PostgresListener/notifications`` stream yields each notification the
    /// server publishes on them. To follow a table's changes, use
    /// ``watchTable(_:table:)`` instead, which installs the publishing
    /// trigger and subscribes for you.
    public static func subscribe(host: String, port: Int, username: String, password: String, database: String, applicationName: String, channels: [String]) throws(PostgresError) -> PostgresListener {
        let target = PostgresConnectionTarget(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        return try PostgresListener(target: target, channels: channels)
    }

    /// Subscribes to `channels` using the same ``PostgresConfiguration`` as a
    /// pooled client, so a subscription and a pool share one configuration. The
    /// subscription manages its own connection.
    public static func subscribe(_ configuration: PostgresConfiguration, channels: [String]) throws(PostgresError) -> PostgresListener {
        try subscribe(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, channels: channels)
    }

    /// Watches `table` using a shared ``PostgresConfiguration``. The publish channel
    /// is derived from the table name.
    public static func watchTable(_ configuration: PostgresConfiguration, table: String) throws(PostgresError) -> PostgresListener {
        try watchTable(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, table: table)
    }

    /// Watches `table` for rows matching `filter`, using a shared ``PostgresConfiguration``.
    public static func watchTable(_ configuration: PostgresConfiguration, table: String, where filter: String) throws(PostgresError) -> PostgresListener {
        try watchTable(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, table: table, where: filter)
    }

    /// Installs an AFTER INSERT/UPDATE/DELETE trigger on `table` that publishes each
    /// changed row as JSON (`{"op":…, "row":…}`) on a channel derived from the table,
    /// then returns a listener subscribed to that channel. Fires for every changed row.
    public static func watchTable(host: String, port: Int, username: String, password: String, database: String, applicationName: String, table: String) throws(PostgresError) -> PostgresListener {
        let target = PostgresConnectionTarget(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        return try watchTable(target: target, table: table, permit: .unlimited())
    }

    /// As ``watchTable(host:port:username:password:database:applicationName:table:)``
    /// but the trigger fires only for rows matching `filter`, a SQL boolean over the
    /// new row, for example `NEW.status = 'active'`. The filter runs in the server,
    /// so the client receives only matching changes.
    public static func watchTable(host: String, port: Int, username: String, password: String, database: String, applicationName: String, table: String, where filter: String) throws(PostgresError) -> PostgresListener {
        let target = PostgresConnectionTarget(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        return try watchTable(target: target, table: table, where: filter, permit: .unlimited())
    }

    static func watchTable(target: PostgresConnectionTarget, table: String, permit: SubscriptionPermit) throws(PostgresError) -> PostgresListener {
        try installChangeTrigger(target: target, table: table, events: "INSERT OR UPDATE OR DELETE", whenClause: "", permit: permit)
    }

    static func watchTable(target: PostgresConnectionTarget, table: String, where filter: String, permit: SubscriptionPermit) throws(PostgresError) -> PostgresListener {
        try installChangeTrigger(target: target, table: table, events: "INSERT OR UPDATE", whenClause: "WHEN (\(filter)) ", permit: permit)
    }

    private static func installChangeTrigger(target: PostgresConnectionTarget, table: String, events: String, whenClause: String, permit: SubscriptionPermit) throws(PostgresError) -> PostgresListener {
        let channel = changeChannelName(forTable: table)
        let function = "dx_notify_\(channel)"
        let trigger = "dx_trg_\(channel)"
        let setup = try target.connect()
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
        return try PostgresListener(target: target, channels: [channel], permit: permit)
    }

    private static func changeChannelName(forTable table: String) -> String {
        let identifier = String(table.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(30))
        let checksum = String(Crc16.ccittXmodem(Array(table.utf8)), radix: 16)
        return "dx_watch_\(identifier)_\(checksum)"
    }
}
