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

@testable import DXClickHouse
import Foundation
import NIOCore
import NIOPosix
import Testing

@Suite("ClickHouseClient — withRetry + isRetryableError")
struct ClickHouseClientRetryTests {

    // MARK: - isRetryableError predicate

    @Test("isRetryableError returns true for unexpectedConnectionClose")
    func unexpectedConnectionCloseIsRetryable() {
        #expect(ClickHouseClient.isRetryableError(ClickHouseError.unexpectedConnectionClose))
    }

    @Test("isRetryableError returns true for poolExhausted (transient — pool may free up)")
    func poolExhaustedIsRetryable() {
        #expect(ClickHouseClient.isRetryableError(ClickHouseError.poolExhausted(maxConnections: 10)))
    }

    @Test("isRetryableError returns true for allPoolEndpointsFailed (network blip)")
    func allPoolEndpointsFailedIsRetryable() {
        #expect(ClickHouseClient.isRetryableError(ClickHouseError.allPoolEndpointsFailed(lastError: "")))
    }

    @Test("isRetryableError returns true for truncatedBuffer (partial read after connection drop)")
    func truncatedBufferIsRetryable() {
        #expect(ClickHouseClient.isRetryableError(ClickHouseError.truncatedBuffer(needed: 8, available: 2)))
    }

    @Test("isRetryableError returns false for serverException (the query itself is bad)")
    func serverExceptionIsNotRetryable() {
        let exception = ClickHouseError.ServerException(
            code: 60, name: "DB::TableNotFound", message: "missing", stackTrace: "", nestedMessages: []
        )
        #expect(ClickHouseClient.isRetryableError(ClickHouseError.serverException(exception)) == false)
    }

    @Test("isRetryableError returns false for unknownTypeName (schema mismatch — won't fix on retry)")
    func unknownTypeNameIsNotRetryable() {
        #expect(ClickHouseClient.isRetryableError(ClickHouseError.unknownTypeName("Foo")) == false)
    }

    @Test("isRetryableError returns false for non-ClickHouse, non-NIO errors (e.g., user-thrown)")
    func arbitraryErrorIsNotRetryable() {
        struct CustomError: Error {}
        #expect(ClickHouseClient.isRetryableError(CustomError()) == false)
    }

    @Test("isRetryableError returns true for NIO ChannelError.ioOnClosedChannel")
    func channelErrorIoOnClosedIsRetryable() {
        #expect(ClickHouseClient.isRetryableError(ChannelError.ioOnClosedChannel))
    }

    @Test("isRetryableError returns true for NIO ChannelError.alreadyClosed")
    func channelErrorAlreadyClosedIsRetryable() {
        #expect(ClickHouseClient.isRetryableError(ChannelError.alreadyClosed))
    }

    // MARK: - withRetry orchestration

    private static func makeClient() -> (ClickHouseClient, MultiThreadedEventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "localhost", port: 9000)],
            eventLoopGroup: group
        ))
        return (client, group)
    }

    @Test("withRetry returns immediately if the operation succeeds on the first attempt")
    func successOnFirstAttempt() async throws {
        let (client, group) = Self.makeClient()
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }
        let counter = TestCallCounter()
        let result: Int = try await client.withRetry {
            counter.increment()
            return 42
        }
        #expect(result == 42)
        #expect(counter.value == 1)
    }

    @Test("withRetry rethrows immediately on a non-retryable error (no retry, single attempt)")
    func nonRetryableErrorThrowsImmediately() async throws {
        let (client, group) = Self.makeClient()
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }
        let counter = TestCallCounter()
        struct PermanentError: Error {}
        var thrown: Error?
        do {
            let _: Int = try await client.withRetry {
                counter.increment()
                throw PermanentError()
            }
        } catch {
            thrown = error
        }
        #expect(thrown is PermanentError)
        #expect(counter.value == 1, "non-retryable errors must not retry")
    }

    @Test("withRetry retries on transient errors and succeeds on the second attempt")
    func retriesOnTransientErrorThenSucceeds() async throws {
        let (client, group) = Self.makeClient()
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }
        let counter = TestCallCounter()
        let result: Int = try await client.withRetry(
            attempts: 3,
            backoff: { _ in .nanoseconds(0) }
        ) {
            counter.increment()
            if counter.value == 1 {
                throw ClickHouseError.unexpectedConnectionClose
            }
            return 99
        }
        #expect(result == 99)
        #expect(counter.value == 2, "should retry once after the first attempt's transient failure")
    }

    @Test("withRetry exhausts attempts on persistent transient error and rethrows the last one")
    func exhaustsAttemptsOnPersistentTransientError() async throws {
        let (client, group) = Self.makeClient()
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }
        let counter = TestCallCounter()
        var thrown: Error?
        do {
            let _: Int = try await client.withRetry(
                attempts: 3,
                backoff: { _ in .nanoseconds(0) }
            ) {
                counter.increment()
                throw ClickHouseError.unexpectedConnectionClose
            }
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.unexpectedConnectionClose = received else {
            Issue.record("expected unexpectedConnectionClose, got \(received)")
            return
        }
        #expect(counter.value == 3, "must use all 3 configured attempts before giving up")
    }

    @Test("withRetry passes the attempt index (0-based) to the backoff closure")
    func backoffReceivesAttemptIndex() async throws {
        let (client, group) = Self.makeClient()
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }
        let observed = TestObserver()
        do {
            let _: Int = try await client.withRetry(
                attempts: 3,
                backoff: { attempt in
                    observed.append(attempt)
                    return .nanoseconds(0)
                }
            ) {
                throw ClickHouseError.unexpectedConnectionClose
            }
        } catch {
            // Expected to throw after exhausting attempts.
        }
        // Backoff is called between attempts: after attempt 0 (before retry 1) and
        // after attempt 1 (before retry 2). Final attempt 2 doesn't trigger backoff
        // since there's no further retry.
        #expect(observed.values == [0, 1])
    }

    @Test("withRetry attempts=0 throws invalidRetryAttempts immediately without calling the operation")
    func attemptsZeroThrowsImmediately() async throws {
        let (client, group) = Self.makeClient()
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }
        let counter = TestCallCounter()
        var thrown: Error?
        do {
            let _: Int = try await client.withRetry(attempts: 0) {
                counter.increment()
                return 0
            }
        } catch {
            thrown = error
        }
        #expect(thrown as? ClickHouseError == .invalidRetryAttempts(0))
        #expect(counter.value == 0)
    }

    // MARK: - Backoff math

    @Test("exponentialBackoff produces 100, 200, 400, 800, 1600 ms for attempts 0..4")
    func exponentialBackoffShape() {
        #expect(ClickHouseClient.exponentialBackoff(attempt: 0).nanoseconds == 100_000_000)
        #expect(ClickHouseClient.exponentialBackoff(attempt: 1).nanoseconds == 200_000_000)
        #expect(ClickHouseClient.exponentialBackoff(attempt: 2).nanoseconds == 400_000_000)
        #expect(ClickHouseClient.exponentialBackoff(attempt: 3).nanoseconds == 800_000_000)
        #expect(ClickHouseClient.exponentialBackoff(attempt: 4).nanoseconds == 1_600_000_000)
    }

    @Test("exponentialBackoff caps at attempt 10 to avoid overflow on large attempt counts")
    func exponentialBackoffCaps() {
        let capped = ClickHouseClient.exponentialBackoff(attempt: 50)
        let atCap = ClickHouseClient.exponentialBackoff(attempt: 10)
        #expect(capped == atCap, "attempts beyond 10 should not grow further")
    }

    @Test("exponentialBackoff with a negative attempt clamps to the first-attempt delay rather than trapping on a negative shift")
    func exponentialBackoffNegativeAttemptClamps() {
        // Pre-fix the implementation did `Int64(1) << exponent` with
        // `exponent = min(attempt, 10)`, so a negative attempt
        // produced a negative shift count that traps in Swift's
        // fixed-width-integer shift operator (process crash, not a
        // recoverable error). This is a public API; a caller
        // composing a custom backoff policy could reach it with a
        // negative attempt index via off-by-one arithmetic. Clamping
        // turns the crash into "use the first-attempt delay".
        let firstAttempt = ClickHouseClient.exponentialBackoff(attempt: 0)
        #expect(ClickHouseClient.exponentialBackoff(attempt: -1) == firstAttempt)
        #expect(ClickHouseClient.exponentialBackoff(attempt: -100) == firstAttempt)
    }

    // MARK: - Jittered backoff

    @Test("exponentialBackoffWithJitter with fraction 0 reduces to the unjittered base for every attempt")
    func jitterFractionZeroEqualsBase() {
        for attempt in 0...12 {
            let base = ClickHouseClient.exponentialBackoff(attempt: attempt)
            let jittered = ClickHouseClient.exponentialBackoffWithJitter(
                attempt: attempt, fraction: 0.0
            )
            #expect(jittered == base,
                    "attempt \(attempt): jitter 0 should equal base; got \(jittered.nanoseconds) vs \(base.nanoseconds)")
        }
    }

    @Test("exponentialBackoffWithJitter stays within ±fraction of the base across many samples")
    func jitterStaysWithinBounds() {
        let attempt = 4  // base = 1600 ms
        let fraction = 0.25
        let base = Double(ClickHouseClient.exponentialBackoff(attempt: attempt).nanoseconds)
        let lowerBound = base * (1.0 - fraction)
        let upperBound = base * (1.0 + fraction)
        // Sample many times to catch statistical outliers from a buggy
        // jitter implementation that exceeds bounds intermittently.
        for _ in 0..<1000 {
            let jittered = Double(ClickHouseClient.exponentialBackoffWithJitter(
                attempt: attempt, fraction: fraction
            ).nanoseconds)
            #expect(jittered >= lowerBound,
                    "jittered (\(jittered)) below lower bound (\(lowerBound))")
            #expect(jittered <= upperBound,
                    "jittered (\(jittered)) above upper bound (\(upperBound))")
        }
    }

    @Test("exponentialBackoffWithJitter never returns a negative duration even when fraction would underflow base")
    func jitterNeverNegative() {
        // Attempt 0 with fraction 1.0: base 100 ms, jitter range
        // ±100 ms — i.e., 0 to 200 ms. The clamp inside the helper
        // pins the lower edge at zero rather than going negative.
        for _ in 0..<200 {
            let jittered = ClickHouseClient.exponentialBackoffWithJitter(
                attempt: 0, fraction: 1.0
            )
            #expect(jittered.nanoseconds >= 0,
                    "jittered duration must never be negative; got \(jittered.nanoseconds) ns")
        }
    }

    @Test("exponentialBackoffWithJitter is statistically centered near the base — averaging many samples converges to base")
    func jitterCentered() {
        let attempt = 3  // base = 800 ms
        let fraction = 0.5
        let base = Double(ClickHouseClient.exponentialBackoff(attempt: attempt).nanoseconds)
        var sum: Double = 0
        let samples = 5000
        for _ in 0..<samples {
            sum += Double(ClickHouseClient.exponentialBackoffWithJitter(
                attempt: attempt, fraction: fraction
            ).nanoseconds)
        }
        let mean = sum / Double(samples)
        // Symmetric jitter must produce a sample mean within ~1% of
        // base across 5000 samples. Loose tolerance to avoid flake on
        // a CI runner with biased RNG.
        let tolerance = base * 0.05
        #expect(abs(mean - base) < tolerance,
                "jitter mean (\(mean)) deviates from base (\(base)) by more than tolerance (\(tolerance))")
    }

}

private final class TestCallCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }

}

private final class TestObserver: @unchecked Sendable {

    private let lock = NSLock()
    private var _values: [Int] = []

    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func append(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }

}
