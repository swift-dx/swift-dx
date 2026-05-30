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
import NIOCore

// Retry helpers for transient failures. Production callers wrap
// idempotent operations with `withRetry(...)` so transient network
// errors don't surface as user-visible failures. Non-idempotent
// operations (e.g., INSERT without server-side dedup) should NOT be
// wrapped — duplicate execution can cause data corruption.
//
// Retryable errors are network-class failures: the wire died but
// the server may still be healthy on a different connection.
// Non-retryable errors include server SQL exceptions (the query is
// bad — retrying won't help) and protocol violations (something is
// fundamentally wrong with the codec contract).
extension ClickHouseClient {

    public static func isRetryableError(_ error: Error) -> Bool {
        if let chError = error as? ClickHouseError { return isRetryableClickHouseError(chError) }
        return isRetryableTransportError(error)
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        if error is IOError { return true }
        if let nioChannelError = error as? ChannelError { return isRetryableChannelError(nioChannelError) }
        return false
    }

    private static func isRetryableClickHouseError(_ error: ClickHouseError) -> Bool {
        switch error {
        case .unexpectedConnectionClose, .poolExhausted, .allPoolEndpointsFailed: return true
        case .truncatedBuffer: return true
        default: return false
        }
    }

    private static func isRetryableChannelError(_ error: ChannelError) -> Bool {
        switch error {
        case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .writeMessageTooLarge: return true
        default: return false
        }
    }

    public func withRetry<T: Sendable>(
        attempts: Int = 3,
        backoff: @Sendable (Int) -> TimeAmount = ClickHouseClient.exponentialBackoff,
        operation: () async throws -> T
    ) async throws -> T {
        guard attempts > 0 else {
            throw ClickHouseError.invalidRetryAttempts(attempts)
        }
        switch try await runRetryLoop(attempts: attempts, backoff: backoff, operation: operation) {
        case .succeeded(let value): return value
        case .exhausted: return try await operation()
        }
    }

    private enum RetryLoopOutcome<T: Sendable>: Sendable {

        case succeeded(T)
        case exhausted

    }

    private func runRetryLoop<T: Sendable>(
        attempts: Int,
        backoff: @Sendable (Int) -> TimeAmount,
        operation: () async throws -> T
    ) async throws -> RetryLoopOutcome<T> {
        for attemptIndex in 0..<(attempts - 1) {
            switch try await runRetryAttempt(attemptIndex: attemptIndex, backoff: backoff, operation: operation) {
            case .succeeded(let value): return .succeeded(value)
            case .exhausted: continue
            }
        }
        return .exhausted
    }

    private func runRetryAttempt<T: Sendable>(
        attemptIndex: Int,
        backoff: @Sendable (Int) -> TimeAmount,
        operation: () async throws -> T
    ) async throws -> RetryLoopOutcome<T> {
        do {
            return .succeeded(try await operation())
        } catch {
            if !Self.isRetryableError(error) {
                throw error
            }
            let delay = backoff(attemptIndex)
            try await Task.sleep(nanoseconds: UInt64(max(0, delay.nanoseconds)))
            return .exhausted
        }
    }

    public static func exponentialBackoff(attempt: Int) -> TimeAmount {
        // 100ms, 200ms, 400ms, 800ms, 1600ms, ...
        // Clamp `attempt` to a non-negative range before the shift.
        // Swift's fixed-width integer `<<` traps on a negative shift
        // count, and this is a public API — a caller composing a
        // custom backoff policy could legitimately reach this with a
        // negative value (e.g., off-by-one in their loop). Clamping
        // to 0 turns that into "first-attempt delay" rather than a
        // process crash.
        let exponent = min(max(0, attempt), 10)  // cap at ~100 seconds (1024 * 100ms)
        let milliseconds = 100 * (Int64(1) << exponent)
        return .milliseconds(milliseconds)
    }

    // Jittered variant of `exponentialBackoff`. Returns a duration
    // uniformly distributed in `[base * (1 - fraction), base * (1 + fraction)]`
    // where `base = exponentialBackoff(attempt:)`. Use when many
    // concurrent operations may retry simultaneously — a brief
    // outage that triggers retries on every connected client at the
    // same instant produces a thundering herd if everyone backs off
    // for exactly the same duration. Symmetric jitter de-correlates
    // those retries so the recovering server isn't slammed.
    //
    // `fraction` defaults to 0.25 (±25% of base). Caller-supplied
    // values must be in [0, 1]; 0 reduces to the unjittered base.
    public static func exponentialBackoffWithJitter(
        attempt: Int,
        fraction: Double = 0.25
    ) -> TimeAmount {
        precondition(fraction >= 0.0 && fraction <= 1.0,
                     "jitter fraction must be in [0, 1]; got \(fraction)")
        let base = exponentialBackoff(attempt: attempt)
        guard fraction > 0 else { return base }
        let baseNanos = Double(base.nanoseconds)
        let jitterRange = baseNanos * fraction
        let delta = Double.random(in: -jitterRange...jitterRange)
        let jittered = max(0, baseNanos + delta)
        return .nanoseconds(Int64(jittered))
    }

}
