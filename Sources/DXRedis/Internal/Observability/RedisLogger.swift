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

// Renders RedisLogEvent values into the caller's swift-log Logger. The event is
// built lazily via @autoclosure and only when the level admits the entry, and the
// operation label decodes its verb only inside render, so a command with logging
// at the default level pays one level comparison and nothing else.
struct RedisLogger: Sendable {

    let logger: Logger

    init(_ logger: Logger) {
        self.logger = logger
    }

    @inline(__always)
    func emit(_ event: @autoclosure () -> RedisLogEvent, level: Logger.Level = .debug) {
        guard logger.logLevel <= level else { return }
        let (message, metadata) = render(event())
        logger.log(level: level, "\(message)", metadata: metadata)
    }

    @inline(__always)
    func emitError(_ event: @autoclosure () -> RedisLogEvent) {
        guard logger.logLevel <= .error else { return }
        let (message, metadata) = render(event())
        logger.error("\(message)", metadata: metadata)
    }

    private func render(_ event: RedisLogEvent) -> (Logger.Message, Logger.Metadata) {
        switch event {
        case .connecting(let host, let port):
            return ("connecting", ["host": "\(host)", "port": "\(port)"])
        case .connected(let host, let port, let durationNanos):
            return ("connected", ["host": "\(host)", "port": "\(port)", "duration_ms": "\(milliseconds(durationNanos))"])
        case .connectFailed(let host, let port, let reason):
            return ("connect.failed", ["host": "\(host)", "port": "\(port)", "reason": "\(reason)"])
        case .commandStarted(let label):
            return ("command.started", ["operation": "\(label.name)"])
        case .commandCompleted(let label, let durationNanos):
            return ("command.completed", ["operation": "\(label.name)", "duration_ms": "\(milliseconds(durationNanos))"])
        case .commandFailed(let label, let reason, let durationNanos):
            return ("command.failed", ["operation": "\(label.name)", "reason": "\(reason)", "duration_ms": "\(milliseconds(durationNanos))"])
        case .retryScheduled(let reason, let delayNanos):
            return ("command.retry_scheduled", ["reason": "\(reason)", "delay_ms": "\(milliseconds(delayNanos))"])
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
