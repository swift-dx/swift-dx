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

/// A live `LISTEN`/`NOTIFY` subscription. It owns one dedicated connection driven
/// by a blocking receive loop on its own thread; each notification the server
/// delivers is yielded to ``notifications``. Iterate that stream to react to
/// changes. The loop also watches an interrupt pipe, so ``listen(_:)``,
/// ``unlisten(_:)`` and ``close()`` take effect immediately even while the read is
/// otherwise parked. Ending the iteration, calling ``close()``, or dropping the
/// listener stops the loop and closes the connection.
///
/// The stream buffers a bounded number of notifications. A consumer that falls
/// behind does not stall the server or grow memory without limit: once the buffer
/// is full the oldest pending notifications are dropped, matching the at-most-once
/// nature of `LISTEN`/`NOTIFY`.
public final class PostgresListener: @unchecked Sendable {

    private static let notificationBufferCapacity = 1024

    private let connection: BlockingPostgresConnection
    private let control: ListenerControl
    public let notifications: AsyncThrowingStream<PostgresNotification, Error>

    init(connection: BlockingPostgresConnection, channels: [String]) throws(PostgresError) {
        self.connection = connection
        self.control = try ListenerControl()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PostgresNotification.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(Self.notificationBufferCapacity))
        self.notifications = stream
        for channel in channels {
            try connection.listen(channel) { continuation.yield($0) }
        }
        let control = self.control
        continuation.onTermination = { [connection, control] _ in
            control.requestStop()
            connection.close()
        }
        let thread = Thread { Self.runLoop(connection: connection, control: control, continuation: continuation) }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Adds `channel` to this subscription on its existing connection. Notifications
    /// on it begin flowing to ``notifications`` once the server acknowledges.
    public func listen(_ channel: String) {
        control.enqueue(.listen(channel))
    }

    /// Stops delivering notifications for `channel` without affecting the others.
    public func unlisten(_ channel: String) {
        control.enqueue(.unlisten(channel))
    }

    /// Stops the receive loop and closes the connection. Idempotent. Wakes the loop
    /// immediately even if it is parked in a blocking read.
    public func close() {
        control.requestStop()
        connection.close()
    }

    deinit {
        control.requestStop()
        connection.close()
    }

    private static func runLoop(connection: BlockingPostgresConnection, control: ListenerControl, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation) {
        let outcome = drive(connection: connection, control: control, continuation: continuation)
        connection.close()
        control.close()
        switch outcome {
        case .stopped: continuation.finish()
        case .failed(let error): continuation.finish(throwing: error)
        }
    }

    private static func drive(connection: BlockingPostgresConnection, control: ListenerControl, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation) -> ListenerLoopOutcome {
        while true {
            if case .terminated(let outcome) = step(connection: connection, control: control, continuation: continuation) {
                return outcome
            }
        }
    }

    private static func step(connection: BlockingPostgresConnection, control: ListenerControl, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation) -> ListenerStep {
        do {
            try drainBuffered(connection: connection, continuation: continuation)
            return try pumpRequestsStop(connection: connection, control: control, continuation: continuation) ? .terminated(.stopped) : .keepGoing
        } catch {
            return .terminated(terminalOutcome(control: control, error: error))
        }
    }

    private static func terminalOutcome(control: ListenerControl, error: PostgresError) -> ListenerLoopOutcome {
        control.isStopRequested ? .stopped : .failed(error)
    }

    private static func drainBuffered(connection: BlockingPostgresConnection, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation) throws(PostgresError) {
        while case .notification(let notification) = try connection.nextBufferedNotification() {
            continuation.yield(notification)
        }
    }

    private static func pumpRequestsStop(connection: BlockingPostgresConnection, control: ListenerControl, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation) throws(PostgresError) -> Bool {
        switch connection.waitForReadableOrInterrupt(interruptDescriptor: control.readDescriptor) {
        case .readable:
            try connection.fillReadBuffer()
            return false
        case .interrupt:
            return try applyCommandsRequestStop(connection: connection, control: control, continuation: continuation)
        }
    }

    private static func applyCommandsRequestStop(connection: BlockingPostgresConnection, control: ListenerControl, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation) throws(PostgresError) -> Bool {
        for command in control.drainCommands() {
            if try apply(command: command, connection: connection, continuation: continuation) {
                return true
            }
        }
        return false
    }

    private static func apply(command: ListenerCommand, connection: BlockingPostgresConnection, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation) throws(PostgresError) -> Bool {
        switch command {
        case .stop:
            return true
        case .listen(let channel):
            try connection.listen(channel) { continuation.yield($0) }
            return false
        case .unlisten(let channel):
            try connection.unlisten(channel) { continuation.yield($0) }
            return false
        }
    }
}

extension Postgres {

    /// Subscribes to `channels` and returns a listener whose
    /// ``PostgresListener/notifications`` stream yields each notification the
    /// server publishes on them. To follow a table's changes, use
    /// ``watchTable(_:table:channel:)`` instead, which installs the publishing
    /// trigger and subscribes for you.
    public static func subscribe(host: String, port: Int, username: String, password: String, database: String, applicationName: String, channels: [String]) throws(PostgresError) -> PostgresListener {
        let connection = try BlockingPostgresConnection.connect(host: host, port: port, username: username, password: password, database: database, applicationName: applicationName)
        return try PostgresListener(connection: connection, channels: channels)
    }

    /// Subscribes to `channels` using the same ``PostgresConfiguration`` as a
    /// pooled client, so a subscription and a pool share one configuration. The
    /// subscription manages its own connection.
    public static func subscribe(_ configuration: PostgresConfiguration, channels: [String]) throws(PostgresError) -> PostgresListener {
        try subscribe(host: configuration.host, port: configuration.port, username: configuration.username, password: configuration.password, database: configuration.database, applicationName: configuration.applicationName, channels: channels)
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
