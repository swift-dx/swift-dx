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

extension RedisClient {

    // Runs an operation against the pool, transparently retrying transient
    // failures (pool at capacity, dropped connection, brief server restart) with
    // exponential backoff until the configured budget elapses. Each retry
    // re-acquires a connection, so a connection that died is replaced and a pool
    // that was momentarily full is waited out. Non-transient errors and the
    // budget expiry surface immediately. This is the single boundary that turns
    // every public operation resilient without the caller knowing.
    func withResilience<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws(RedisError) -> Value {
        guard resilience.retryTransientFailures else { return try await RedisError.bridge(operation) }
        return try await retryLoop(operation)
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
