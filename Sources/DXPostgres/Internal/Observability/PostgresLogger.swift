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

// Renders PostgresLogEvent values into the caller's swift-log Logger as a short
// message plus structured metadata. The event is built lazily and only when the
// logger's level admits the entry, so disabled instrumentation costs nothing on
// the hot path. The duration fields arrive in nanoseconds and are rendered as
// milliseconds for readability.
struct PostgresLogger: Sendable {

    let logger: Logger

    init(_ logger: Logger) {
        self.logger = logger
    }

    @inline(__always)
    func emit(_ event: @autoclosure () -> PostgresLogEvent, level: Logger.Level = .debug) {
        guard logger.logLevel <= level else { return }
        let (message, metadata) = render(event())
        logger.log(level: level, "\(message)", metadata: metadata)
    }

    @inline(__always)
    func emitError(_ event: @autoclosure () -> PostgresLogEvent) {
        guard logger.logLevel <= .error else { return }
        let (message, metadata) = render(event())
        logger.error("\(message)", metadata: metadata)
    }

    private func render(_ event: PostgresLogEvent) -> (Logger.Message, Logger.Metadata) {
        switch event {
        case .connecting(let host, let port):
            return ("connecting", ["host": "\(host)", "port": "\(port)"])
        case .connected(let host, let port, let durationNanos):
            return ("connected", ["host": "\(host)", "port": "\(port)", "duration_ms": "\(milliseconds(durationNanos))"])
        case .connectFailed(let host, let port, let reason):
            return ("connect.failed", ["host": "\(host)", "port": "\(port)", "reason": "\(reason)"])
        case .queryStarted(let statement):
            return ("query.started", ["operation": "\(PostgresStatementDescriptor.operation(of: statement))", "statement": "\(statement)"])
        case .queryCompleted(let statement, let durationNanos):
            return ("query.completed", ["operation": "\(PostgresStatementDescriptor.operation(of: statement))", "duration_ms": "\(milliseconds(durationNanos))"])
        case .queryFailed(let statement, let reason, let durationNanos):
            return ("query.failed", ["operation": "\(PostgresStatementDescriptor.operation(of: statement))", "reason": "\(reason)", "duration_ms": "\(milliseconds(durationNanos))"])
        case .retryScheduled(let reason, let delayNanos):
            return ("query.retry_scheduled", ["reason": "\(reason)", "delay_ms": "\(milliseconds(delayNanos))"])
        case .poolExhausted(let maxConnections):
            return ("pool.exhausted", ["max_connections": "\(maxConnections)"])
        case .poolShutdown:
            return ("pool.shutdown", [:])
        }
    }

    private func milliseconds(_ nanos: UInt64) -> String {
        String(format: "%.3f", Double(nanos) / 1_000_000)
    }
}
