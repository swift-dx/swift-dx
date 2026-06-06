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
import Logging
import Synchronization

// Drives one subscription's connection on its own thread: it drains notifications,
// applies queued listen/unlisten/stop commands the moment the wakeup pipe fires,
// and, when the connection is reconnectable, rebuilds it forever after a drop and
// re-issues every active channel before resuming. The current connection lives in a
// shared box so the listener's close() can shut whichever connection the loop is
// using at the time, even across a reconnect.
//
// `@unchecked Sendable` is sound because the channel set is touched only by this
// owning thread, the current-connection box is a mutex, and the control channel and
// stream continuation are themselves thread-safe.
final class SubscriptionReceiveLoop: @unchecked Sendable {

    private static let initialBackoffSeconds = 0.05
    private static let maxBackoffSeconds = 30.0

    private let currentConnection: Mutex<BlockingPostgresConnection>
    private let source: ListenerSource
    private let control: ListenerControl
    private let continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation
    private let logger: Logger
    private var channels: Set<String>

    init(connection: BlockingPostgresConnection, source: ListenerSource, control: ListenerControl, continuation: AsyncThrowingStream<PostgresNotification, Error>.Continuation, channels: Set<String>) {
        self.currentConnection = Mutex(connection)
        self.source = source
        self.control = control
        self.continuation = continuation
        self.channels = channels
        self.logger = Logger(label: "dx.postgres.subscription")
    }

    func listen(_ channel: String) {
        control.enqueue(.listen(channel))
    }

    func unlisten(_ channel: String) {
        control.enqueue(.unlisten(channel))
    }

    func requestStop() {
        control.requestStop()
        currentConnection.withLock { $0.close() }
    }

    func run() {
        while advance(outcome: driveCurrentConnection()) {}
    }

    private func driveCurrentConnection() -> ListenerLoopOutcome {
        let connection = currentConnection.withLock { $0 }
        let outcome = drive(connection: connection)
        connection.close()
        return outcome
    }

    private func advance(outcome: ListenerLoopOutcome) -> Bool {
        switch outcome {
        case .stopped:
            return finishClean()
        case .failed(let error):
            return advanceAfterFailure(error: error)
        }
    }

    private func advanceAfterFailure(error: PostgresError) -> Bool {
        switch recover(error: error) {
        case .reconnected:
            return true
        case .stop:
            return finishClean()
        case .fail(let error):
            return finishFailed(error: error)
        }
    }

    private func finishClean() -> Bool {
        terminate()
        continuation.finish()
        return false
    }

    private func finishFailed(error: PostgresError) -> Bool {
        terminate()
        continuation.finish(throwing: error)
        return false
    }

    private func terminate() {
        currentConnection.withLock { $0.close() }
        control.close()
    }

    private func recover(error: PostgresError) -> ListenerRecovery {
        if control.isStopRequested { return .stop }
        guard case .reconnectable(let target) = source else { return .fail(error) }
        logger.warning("postgres subscription connection lost; reconnecting in the background")
        return reconnect(target: target)
    }

    private func reconnect(target: PostgresConnectionTarget) -> ListenerRecovery {
        var delaySeconds = Self.initialBackoffSeconds
        while !control.isStopRequested {
            do {
                try establish(target: target)
                control.resignalIfPending()
                logger.notice("postgres subscription connection recovered")
                return .reconnected
            } catch {
                control.waitForSignal(timeoutSeconds: delaySeconds)
                delaySeconds = min(delaySeconds * 2, Self.maxBackoffSeconds)
            }
        }
        return .stop
    }

    private func establish(target: PostgresConnectionTarget) throws(PostgresError) {
        let connection = try target.connect()
        currentConnection.withLock { $0 = connection }
        for channel in channels {
            try connection.listen(channel) { continuation.yield($0) }
        }
    }

    private func drive(connection: BlockingPostgresConnection) -> ListenerLoopOutcome {
        while true {
            if case .terminated(let outcome) = step(connection: connection) {
                return outcome
            }
        }
    }

    private func step(connection: BlockingPostgresConnection) -> ListenerStep {
        do {
            try drainBuffered(connection: connection)
            return try pumpRequestsStop(connection: connection) ? .terminated(.stopped) : .keepGoing
        } catch {
            return .terminated(terminalOutcome(error: error))
        }
    }

    private func terminalOutcome(error: PostgresError) -> ListenerLoopOutcome {
        control.isStopRequested ? .stopped : .failed(error)
    }

    private func drainBuffered(connection: BlockingPostgresConnection) throws(PostgresError) {
        while case .notification(let notification) = try connection.nextBufferedNotification() {
            continuation.yield(notification)
        }
    }

    private func pumpRequestsStop(connection: BlockingPostgresConnection) throws(PostgresError) -> Bool {
        switch connection.waitForReadableOrInterrupt(interruptDescriptor: control.readDescriptor) {
        case .readable:
            try connection.fillReadBuffer()
            return false
        case .interrupt:
            return try applyCommandsRequestStop(connection: connection)
        }
    }

    private func applyCommandsRequestStop(connection: BlockingPostgresConnection) throws(PostgresError) -> Bool {
        for command in control.drainCommands() {
            if try apply(command: command, connection: connection) {
                return true
            }
        }
        return false
    }

    private func apply(command: ListenerCommand, connection: BlockingPostgresConnection) throws(PostgresError) -> Bool {
        switch command {
        case .stop:
            return true
        case .listen(let channel):
            try connection.listen(channel) { continuation.yield($0) }
            channels.insert(channel)
            return false
        case .unlisten(let channel):
            try connection.unlisten(channel) { continuation.yield($0) }
            channels.remove(channel)
            return false
        }
    }
}
