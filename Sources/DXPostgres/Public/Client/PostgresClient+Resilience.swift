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

extension PostgresClient {

    // Runs a single-query operation against the pool, transparently retrying
    // transient failures on a freshly acquired connection with exponential
    // backoff until the request-timeout budget elapses. Each retry re-acquires a
    // connection, so a connection that died or went half-open is replaced and a
    // momentarily full pool is waited out. Non-transient errors and budget expiry
    // surface immediately. This is the single boundary that makes every plain
    // query self-healing; transactions, COPY, and streams deliberately do not run
    // through it because replaying them partially would be unsafe.
    //
    // It is also the one place every logical query passes through, so it owns the
    // per-query observability: a client tracing span, the latency measurement, and
    // the query/error counters. Retries happen inside the span and bump the retry
    // counter, so one logical query is one span and one latency sample regardless
    // of how many physical attempts it took.
    func withResilience<Value: Sendable>(statement: String, _ operation: @Sendable () async throws -> Value) async throws(PostgresError) -> Value {
        observability.logger.emit(.queryStarted(statement: statement))
        let start = NIODeadline.now()
        do {
            let value = try await traced(statement) {
                try await self.executeWithRetries(operation)
            }
            recordCompletion(statement, start: start)
            return value
        } catch {
            throw recordFailure(statement, start: start, error: PostgresError.translate(error))
        }
    }

    // The span name is a constant, so it costs nothing to build. The attribute
    // values (including the leading-keyword scan of the SQL) are computed only
    // when the span is actually recording, so a read/write with no tracer
    // bootstrapped never scans the statement.
    private func traced<Value: Sendable>(_ statement: String, _ body: @Sendable () async throws -> Value) async throws -> Value {
        try await withSpan("postgres.query", ofKind: .client) { span in
            if span.isRecording {
                span.attributes["db.system"] = "postgresql"
                span.attributes["db.operation"] = PostgresStatementDescriptor.operation(of: statement)
                span.attributes["db.statement"] = statement
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

    private func recordCompletion(_ statement: String, start: NIODeadline) {
        let elapsed = nanosSince(start)
        observability.metrics.recordQuery(durationNanos: elapsed)
        observability.logger.emit(.queryCompleted(statement: statement, durationNanos: elapsed))
    }

    private func recordFailure(_ statement: String, start: NIODeadline, error: PostgresError) -> PostgresError {
        let elapsed = nanosSince(start)
        observability.metrics.recordQuery(durationNanos: elapsed)
        observability.metrics.recordError()
        observability.logger.emitError(.queryFailed(statement: statement, reason: "\(error)", durationNanos: elapsed))
        return error
    }

    private func nanosSince(_ start: NIODeadline) -> UInt64 {
        UInt64(max((NIODeadline.now() - start).nanoseconds, 0))
    }

    private func retryLoop<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws(PostgresError) -> Value {
        let deadline = NIODeadline.now() + requestTimeout
        var delay = resilience.reconnectBaseDelay
        while true {
            do {
                return try await operation()
            } catch {
                try await retryOrThrow(PostgresError.translate(error), deadline: deadline, delay: &delay)
            }
        }
    }

    private func retryOrThrow(_ error: PostgresError, deadline: NIODeadline, delay: inout TimeAmount) async throws(PostgresError) {
        guard error.isTransient, NIODeadline.now() < deadline else { throw error }
        observability.metrics.recordRetry()
        observability.logger.emit(.retryScheduled(reason: "\(error)", delayNanos: UInt64(max(delay.nanoseconds, 0))), level: .warning)
        try await backoff(&delay)
    }

    private func backoff(_ delay: inout TimeAmount) async throws(PostgresError) {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(delay.nanoseconds, 0)))
        } catch {
            throw PostgresError.cancelled
        }
        delay = min(.nanoseconds(delay.nanoseconds &* 2), resilience.reconnectMaxDelay)
    }
}
