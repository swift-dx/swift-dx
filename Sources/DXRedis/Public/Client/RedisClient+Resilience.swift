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

import NIOCore
import Tracing

extension RedisClient {

    // Runs an operation against the pool, transparently retrying transient
    // failures (pool at capacity, dropped connection, brief server restart) with
    // exponential backoff until the configured budget elapses. Each retry
    // re-acquires a connection, so a connection that died is replaced and a pool
    // that was momentarily full is waited out. Non-transient errors and the
    // budget expiry surface immediately. This is the single boundary that turns
    // every public operation resilient without the caller knowing.
    //
    // It is also where per-operation observability lives: one client span, one
    // latency sample, and the command/error counters. The operation label decodes
    // its verb lazily and span attributes are set only when the span is recording,
    // so with no tracer and default log level the hot path adds two clock reads,
    // relaxed-atomic counter updates, and no-op instrument calls — no allocations
    // and no string work.
    func withResilience<Value: Sendable>(_ label: RedisOperationLabel, _ operation: @Sendable () async throws -> Value) async throws(RedisError) -> Value {
        observability.logger.emit(.commandStarted(label: label))
        let start = NIODeadline.now()
        do {
            let value = try await traced(label) { try await self.executeWithRetries(operation) }
            recordCompletion(label, start: start)
            return value
        } catch {
            throw recordFailure(label, start: start, error: RedisError.translate(error))
        }
    }

    private func traced<Value: Sendable>(_ label: RedisOperationLabel, _ body: @Sendable () async throws -> Value) async throws -> Value {
        try await withSpan("redis.command", ofKind: .client) { span in
            if span.isRecording {
                span.attributes["db.system"] = "redis"
                span.attributes["db.operation"] = label.name
            }
            return try await self.runRecording(into: span, body)
        }
    }

    private func runRecording<Value: Sendable>(into span: any Span, _ body: @Sendable () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            span.recordError(error)
            throw error
        }
    }

    private func executeWithRetries<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        guard resilience.retryTransientFailures else { return try await operation() }
        return try await retryLoop(operation)
    }

    private func recordCompletion(_ label: RedisOperationLabel, start: NIODeadline) {
        let elapsed = nanosSince(start)
        observability.metrics.recordCommand(durationNanos: elapsed)
        observability.logger.emit(.commandCompleted(label: label, durationNanos: elapsed))
    }

    private func recordFailure(_ label: RedisOperationLabel, start: NIODeadline, error: RedisError) -> RedisError {
        let elapsed = nanosSince(start)
        observability.metrics.recordCommand(durationNanos: elapsed)
        observability.metrics.recordError()
        observability.logger.emitError(.commandFailed(label: label, reason: "\(error)", durationNanos: elapsed))
        return error
    }

    private func nanosSince(_ start: NIODeadline) -> UInt64 {
        UInt64(max((NIODeadline.now() - start).nanoseconds, 0))
    }

    private func retryLoop<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws(RedisError) -> Value {
        let deadline = NIODeadline.now() + resilience.requestTimeout
        var delay = resilience.reconnectBaseDelay
        while true {
            do {
                return try await operation()
            } catch {
                try await retryOrThrow(RedisError.translate(error), deadline: deadline, delay: &delay)
            }
        }
    }

    private func retryOrThrow(_ error: RedisError, deadline: NIODeadline, delay: inout TimeAmount) async throws(RedisError) {
        guard error.isTransient, NIODeadline.now() < deadline else { throw error }
        observability.metrics.recordRetry()
        observability.logger.emit(.retryScheduled(reason: "\(error)", delayNanos: UInt64(max(delay.nanoseconds, 0))), level: .warning)
        try await backoff(&delay)
    }

    private func backoff(_ delay: inout TimeAmount) async throws(RedisError) {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(delay.nanoseconds, 0)))
        } catch {
            throw RedisError.cancelled
        }
        delay = min(.nanoseconds(delay.nanoseconds &* 2), resilience.reconnectMaxDelay)
    }
}
