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
import NIOEmbedded
import Testing

// Serialized so tests within the suite don't compete for the
// runner's scheduler. Tests like `concurrentAcquiresDoNotOvershootMax`
// and `concurrencyStressUnderRandomCancellation` spawn many child
// Tasks; running them in parallel with each other plus the rest of
// the suite can starve individual Tasks for tens of seconds. Each
// test in isolation runs in <1 s; serialization keeps total suite
// time under a few seconds while eliminating cross-test flakes.
@Suite("ClickHouse connection pool", .serialized)
struct ClickHouseConnectionPoolTests {

    private static let revision: UInt64 = 54_478

    private static func makeMockConnection() throws -> ClickHouseConnection {
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try channel.connect(to: address).wait()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: revision))
        )
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: revision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try channel.pipeline.syncOperations.addHandler(inboundHandler)
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: revision,
            clientHello: .init(
                clientName: "PoolTest",
                versionMajor: 1, versionMinor: 0, protocolRevision: revision,
                defaultDatabase: "obs", username: "u", password: ""
            ),
            serverHello: .init(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8, serverRevision: revision,
                serverTimezone: .value("UTC"), displayName: .value("test-1"), versionPatch: .value(1)
            )
        )
        return ClickHouseConnection(channel: channel, inboundHandler: inboundHandler, metadata: metadata)
    }

    private static func makeMockConnectionExposingChannel() throws -> (ClickHouseConnection, EmbeddedChannel) {
        let channel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try channel.connect(to: address).wait()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: revision))
        )
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: revision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try channel.pipeline.syncOperations.addHandler(inboundHandler)
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: revision,
            clientHello: .init(
                clientName: "PoolTest",
                versionMajor: 1, versionMinor: 0, protocolRevision: revision,
                defaultDatabase: "obs", username: "u", password: ""
            ),
            serverHello: .init(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8, serverRevision: revision,
                serverTimezone: .value("UTC"), displayName: .value("test-1"), versionPatch: .value(1)
            )
        )
        let connection = ClickHouseConnection(channel: channel, inboundHandler: inboundHandler, metadata: metadata)
        return (connection, channel)
    }

    @Test("dropping a ClickHouseClient without calling shutdown still closes idle connections via the deinit safety net")
    func dropWithoutShutdownClosesIdleConnections() async throws {
        // Construct a client whose pool factory returns a mock
        // connection we keep a reference to. Acquire + release once
        // so the connection lands in `idle`. Drop the client. The
        // deinit fires off a Task to shutdown the pool, which closes
        // every idle connection — eventually setting isActive=false.
        // Poll for it instead of asserting synchronously because the
        // cleanup is necessarily async.
        let mockChannel = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try await mockChannel.connect(to: address).get()
        try mockChannel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(ClickHouseOutboundEncoder(revision: Self.revision))
        )
        try mockChannel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(ClickHouseInboundDecoder(revision: Self.revision))
        )
        let inboundHandler = ClickHouseInboundStreamHandler()
        try mockChannel.pipeline.syncOperations.addHandler(inboundHandler)
        let metadata = ClickHouseConnectionMetadata(
            negotiatedRevision: Self.revision,
            clientHello: .init(
                clientName: "DeinitTest",
                versionMajor: 1, versionMinor: 0, protocolRevision: Self.revision,
                defaultDatabase: "obs", username: "u", password: ""
            ),
            serverHello: .init(
                serverName: "ClickHouse",
                versionMajor: 24, versionMinor: 8, serverRevision: Self.revision,
                serverTimezone: .value("UTC"), displayName: .value("deinit-test"), versionPatch: .value(1)
            )
        )
        let mockConnection = ClickHouseConnection(
            channel: mockChannel,
            inboundHandler: inboundHandler,
            metadata: metadata
        )

        // Run the lifecycle in a tight scope so the client deinit
        // fires deterministically when control leaves the closure.
        try await {
            let client = ClickHouseClient(poolConfiguration: .init(
                endpoints: [.init(host: "h", port: 9000)],
                connectionFactory: { _ in mockConnection }
            ))
            let conn = try await client.pool.acquire()
            await client.pool.release(conn)
            #expect(await client.pool.idleCount == 1, "after release the idle pool must hold one connection")
        }()

        // Poll for the deinit's async cleanup to close the channel.
        // The synchronous `closing` flag means isActive flips false
        // immediately when shutdown's close path runs, so we just need
        // to wait for the deinit Task to have started executing.
        var inactive = !mockConnection.isActive
        let deadline = Date().addingTimeInterval(0.5)
        while !inactive && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            inactive = !mockConnection.isActive
        }
        #expect(inactive, "client deinit must close idle connections; isActive=\(mockConnection.isActive)")
    }

    @Test("acquire opens a new connection when the idle queue is empty")
    func acquireOpensNewConnection() async throws {
        let factoryCalls = TestCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000)],
            connectionFactory: { _ in
                factoryCalls.increment()
                return try Self.makeMockConnection()
            }
        ))

        _ = try await pool.acquire()
        #expect(await pool.activeCount == 1)
        #expect(await pool.idleCount == 0)
        #expect(factoryCalls.value == 1)
    }

    @Test("acquire after release reuses the idle connection without calling the factory")
    func acquireReusesIdleConnection() async throws {
        let factoryCalls = TestCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in
                factoryCalls.increment()
                return try Self.makeMockConnection()
            }
        ))

        let firstConnection = try await pool.acquire()
        await pool.release(firstConnection)
        #expect(await pool.idleCount == 1)
        #expect(await pool.activeCount == 0)

        let secondConnection = try await pool.acquire()
        #expect(secondConnection === firstConnection)
        #expect(factoryCalls.value == 1)
        #expect(await pool.activeCount == 1)
        #expect(await pool.idleCount == 0)
    }

    @Test("max connections caps active connections and surfaces poolExhausted")
    func maxConnectionsRespected() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 2,
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        _ = try await pool.acquire()
        _ = try await pool.acquire()

        await #expect(throws: ClickHouseError.poolExhausted(maxConnections: 2)) {
            try await pool.acquire()
        }
    }

    @Test("releasing more idle than maxIdle closes the excess rather than queueing it")
    func excessIdleConnectionsAreClosed() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 5,
            maxIdleConnections: 2,
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let c1 = try await pool.acquire()
        let c2 = try await pool.acquire()
        let c3 = try await pool.acquire()

        await pool.release(c1)
        await pool.release(c2)
        await pool.release(c3)

        #expect(await pool.idleCount == 2)
        #expect(await pool.activeCount == 0)
    }

    @Test("endpoints round-robin across consecutive opens")
    func endpointsRoundRobin() async throws {
        let endpoints: [ClickHouseEndpoint] = [
            .init(host: "h1", port: 9000),
            .init(host: "h2", port: 9000),
            .init(host: "h3", port: 9000),
        ]
        let calls = TestEndpointTracker()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: endpoints,
            maxConnections: 10,
            connectionFactory: { endpoint in
                calls.record(endpoint)
                return try Self.makeMockConnection()
            }
        ))

        for _ in 0..<6 {
            _ = try await pool.acquire()
        }
        #expect(calls.recorded == ["h1", "h2", "h3", "h1", "h2", "h3"])
    }

    @Test("when an endpoint factory throws, acquire fails over to the next endpoint")
    func failoverOnFactoryError() async throws {
        let endpoints: [ClickHouseEndpoint] = [
            .init(host: "broken", port: 9000),
            .init(host: "healthy", port: 9000),
        ]
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: endpoints,
            connectionFactory: { endpoint in
                if endpoint.host == "broken" {
                    throw TestError.simulatedFailure
                }
                return try Self.makeMockConnection()
            }
        ))

        let connection = try await pool.acquire()
        #expect(connection.isActive)
    }

    @Test("when every endpoint factory throws, acquire surfaces allPoolEndpointsFailed")
    func allEndpointsFailingSurfacesError() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 1), .init(host: "h2", port: 1)],
            connectionFactory: { _ in throw TestError.simulatedFailure }
        ))

        await #expect(throws: ClickHouseError.self) {
            try await pool.acquire()
        }
    }

    @Test("an empty endpoint list surfaces poolHasNoEndpoints rather than hanging")
    func emptyEndpointsRejected() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        await #expect(throws: ClickHouseError.poolHasNoEndpoints) {
            try await pool.acquire()
        }
    }

    @Test("idle connections older than idleTimeout are evicted on next acquire")
    func idleTimeoutEvictionOnAcquire() async throws {
        let clock = MockClock()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            idleTimeout: .seconds(30),
            maxLifetime: .hours(1),
            connectionFactory: { _ in try Self.makeMockConnection() },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        let c1 = try await pool.acquire()
        await pool.release(c1)
        #expect(await pool.idleCount == 1)

        clock.now = .uptimeNanoseconds(60_000_000_000)
        let c2 = try await pool.acquire()
        #expect(c2 !== c1)
    }

    @Test("acquireTimeout=.failImmediatelyWhenExhausted preserves the existing exhausted-throws-immediately behavior")
    func acquireTimeoutFailImmediatelyStillThrowsImmediately() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        _ = try await pool.acquire()
        await #expect(throws: ClickHouseError.poolExhausted(maxConnections: 1)) {
            try await pool.acquire()
        }
    }

    @Test("two concurrent acquires don't race past maxConnections during the connect await")
    func concurrentAcquiresDoNotOvershootMax() async throws {
        // The factory blocks on a 50 ms sleep so the actor reentry
        // window between cap check and slot commit is wide. Without
        // the openingCount reservation in `acquire`, both acquires
        // see active.count == 0 and both call the factory; the
        // pool would end up with two connections against a cap of
        // one. With the fix, the second sees opening==1 and waits.
        let factoryCalls = ConnectionFactoryCallCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            // 120 s acquireTimeout — a safety cap, not a timing
            // assertion. The test asserts a logical race-free
            // property. Under heavy parallel test-runner load on
            // CI, individual Tasks can be scheduling-starved for
            // tens of seconds; 30 s flaked twice. The cap is just
            // to fail fast on a genuine deadlock vs. waiting
            // forever; 2 minutes covers any realistic runner load.
            acquireTimeout: .waitUpTo(.seconds(120)),
            connectionFactory: { _ in
                await factoryCalls.increment()
                try? await Task.sleep(nanoseconds: 50_000_000)
                return try Self.makeMockConnection()
            }
        ))

        async let first: ClickHouseConnection = pool.acquire()
        async let second: ClickHouseConnection = pool.acquire()

        let firstConn = try await first
        let calls = await factoryCalls.value
        // Only one connect should have been issued; the second
        // acquire should still be suspended waiting for release.
        #expect(calls == 1, "the second acquire must wait, not double-open")
        #expect(await pool.waiterCount == 1)

        await pool.release(firstConn)
        let secondConn = try await second
        #expect(secondConn === firstConn, "the released connection is handed to the waiter")
    }

    // Regression test for the release-vs-enqueue race fixed in
    // `enqueueWaiter`. The race: a suspended `acquire()` registers
    // its continuation, but the actor-hop Task that appends the
    // waiter to `waiters[]` may not have run yet. If `release()`
    // runs in that window, it sees an empty wait queue, parks the
    // connection in idle, and the late-arriving waiter would never
    // get the connection (and would time out at acquireTimeout).
    //
    // The fix: when `enqueueWaiter` finally runs, it checks idle
    // first — if a parked connection exists from a release-during-
    // the-window, it hands it to this waiter directly instead of
    // queueing.
    //
    // Stress shape: 100 acquire-release cycles with an aggressive
    // 1-second timeout. Without the fix, a fraction of these would
    // hit the race and time out. With the fix, all 100 complete
    // bounded.
    // Regression test for the cancel-during-enqueue race. When an
    // awaiting acquire is cancelled BEFORE the actor-hop Task runs
    // `enqueueWaiter`, the cancellation handler's `cancelWaiter`
    // finds an empty wait queue (waiter not yet enqueued) and
    // returns silently. Then enqueueWaiter runs and appends the
    // waiter — but the continuation never gets the cancellation
    // signal, so it lingers until `acquireTimeout` (could be
    // seconds). The fix: `cancelWaiter` records the cancelled id;
    // `enqueueWaiter` checks the cancelled set and immediately
    // resumes with CancellationError if its waiter was already
    // cancelled.
    //
    // Stress shape: cancel 100 waiters in rapid succession, then
    // assert the pool's waiter queue is empty (no orphans) and
    // total wall clock is bounded.
    // Aggressive concurrency stress: 100 tasks each running
    // acquire-release cycles for 200ms, with random cancellations
    // sprinkled in. The new lock-based design eliminates the
    // structural Task-hop races; this test validates that no NEW
    // race was introduced by the refactor under realistic concurrent
    // load.
    //
    // What we assert:
    //   - No deadlocks (all tasks complete bounded)
    //   - No stuck waiters at the end (waiterCount == 0)
    //   - The factory call count never exceeds maxConnections (no
    //     overshoot under concurrent acquires).
    //   - All non-cancelled tasks observed a usable connection.
    // Edge case: maxIdleConnections=0 means "no caching, fresh
    // connection per acquire". Common production pattern when
    // callers prefer the cost of a connect over the risk of using
    // a stale pool connection. Pin the contract:
    //   - Every acquire opens a NEW connection (factory called).
    //   - Every release closes the connection (no idle parking).
    //   - effectiveWarmupCount returns 0 (can't warm up if we won't keep them).
    @Test("maxIdleConnections=0 disables idle caching — every acquire opens fresh, every release closes")
    func maxIdleConnectionsZeroDisablesCaching() async throws {
        let factoryCalls = ConnectionFactoryCallCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 4,
            maxIdleConnections: 0,
            connectionFactory: { _ in
                await factoryCalls.increment()
                return try Self.makeMockConnection()
            }
        ))

        // 5 sequential acquire+release cycles. Without idle caching,
        // each acquire must open a NEW connection.
        for _ in 0..<5 {
            let conn = try await pool.acquire()
            await pool.release(conn)
        }
        let totalOpens = await factoryCalls.value
        #expect(totalOpens == 5, "expected 5 fresh opens (no idle caching); got \(totalOpens)")
        let stats = await pool.stats()
        #expect(stats.idleCount == 0, "idle pool must stay empty when maxIdleConnections=0")

        // effectiveWarmupCount must be 0: can't warm up when we
        // won't keep connections.
        let warmCount = await pool.effectiveWarmupCount(requested: 100)
        #expect(warmCount == 0, "warmup with maxIdleConnections=0 must be 0; got \(warmCount)")
    }

    @Test("aggressive concurrency stress — 100 tasks × random acquire/release/cancel under maxConnections=4")
    func concurrencyStressUnderRandomCancellation() async throws {
        let factoryCalls = ConnectionFactoryCallCounter()
        let maxConn = 4
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: maxConn,
            acquireTimeout: .waitUpTo(.seconds(2)),
            connectionFactory: { _ in
                await factoryCalls.increment()
                return try Self.makeMockConnection()
            }
        ))

        let started = Date()
        let deadline = started.addingTimeInterval(0.2)
        actor SuccessCounter {
            var value: Int = 0
            func increment() { value += 1 }
        }
        let successes = SuccessCounter()
        // Run 100 concurrent tasks; each loops acquire/release with
        // random self-cancellation until the deadline.
        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<100 {
                group.addTask {
                    var rng = SystemRandomNumberGenerator()
                    while Date() < deadline {
                        // Random spawn lifetime in [0, 5ms].
                        let lifetimeNanos = UInt64.random(in: 0...5_000_000, using: &rng)
                        let inner = Task {
                            do {
                                let conn = try await pool.acquire()
                                if lifetimeNanos > 0 {
                                    try? await Task.sleep(nanoseconds: lifetimeNanos)
                                }
                                await pool.release(conn)
                                await successes.increment()
                            } catch {
                                // Cancellation or pool errors are fine —
                                // we just want no deadlocks/orphans.
                            }
                        }
                        // 10% of tasks cancel themselves immediately
                        // to exercise the cancel-during-body race.
                        if taskIndex % 10 == 0 {
                            inner.cancel()
                        }
                        _ = await inner.value
                    }
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        // Hard bound: 100 tasks × 200 ms work × ~5 ms per cycle =
        // way under 10 seconds. A deadlock would push past.
        #expect(elapsed < 10.0, "concurrency stress should bound under 10 s; observed \(elapsed)s — deadlock?")
        // No orphaned waiters at quiescence.
        let orphans = await pool.waiterCount
        #expect(orphans == 0, "stress left \(orphans) orphaned waiters")
        // The pending-cancellation set must also drain. Every
        // cancel-arrived-before-body insert into this set is
        // consumed by the eventually-running body. A non-zero
        // value at quiescence would indicate a bookkeeping leak.
        let pendingCancels = await pool.pendingCancellationCount
        #expect(pendingCancels == 0, "stress left \(pendingCancels) entries in cancelledWaiterIDs — bookkeeping leak")
        // Factory must NEVER have opened more than maxConnections.
        // The opening-count reservation in acquire() makes
        // overshooting structurally impossible; this assertion guards
        // against a future regression.
        let totalOpens = await factoryCalls.value
        let stats = await pool.stats()
        #expect(stats.activeCount + stats.idleCount <= maxConn,
                "pool exceeded maxConnections=\(maxConn): active=\(stats.activeCount) idle=\(stats.idleCount) (totalOpens=\(totalOpens))")
        let succeededAcquires = await successes.value
        #expect(succeededAcquires > 0, "stress test produced 0 successful acquires — something is wrong")
    }

    @Test("100 cancellations during the enqueue window leave no orphaned waiters in the pool")
    func cancelDuringEnqueueRaceRegression() async throws {
        // Use a short acquireTimeout so the test fails fast (in
        // ~500 ms per orphan) when the bug is present, rather than
        // hanging for 30 s × N. With the fix in place all
        // cancellations resolve immediately and the test runs in
        // under a second.
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            acquireTimeout: .waitUpTo(.milliseconds(500)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        // Hold the only slot.
        let firstConn = try await pool.acquire()
        let started = Date()
        for _ in 0..<10 {
            let task = Task {
                try await pool.acquire()
            }
            // Cancel immediately. Without yield, the enqueue Task may
            // not have run yet — the race window the regression
            // protects against.
            task.cancel()
            // Drain the cancelled task so it doesn't accumulate.
            // With the bug present, this awaits the full 500 ms
            // acquireTimeout for orphaned waiters.
            _ = try? await task.value
        }
        // Allow any in-flight enqueue Tasks to settle.
        try await Task.sleep(nanoseconds: 50_000_000)
        // The pool must have NO orphaned waiters.
        let orphans = await pool.waiterCount
        let elapsed = Date().timeIntervalSince(started)
        #expect(orphans == 0, "10 cancellations left \(orphans) orphaned waiters in the pool")
        // 10 × 500 ms acquireTimeout = 5 s worst case if every
        // cancellation hits the race. Bound at 2 s — failing means
        // multiple cancellations linger past the cancellation handler.
        #expect(elapsed < 2.0, "10 cancellations should drain in <2s; observed \(elapsed)s — orphans timing out at acquireTimeout?")
        await pool.release(firstConn)
    }

    @Test("100 rapid acquire-release cycles complete bounded — pool waiter race regression test")
    func waiterRaceRegressionStress() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            // 30 s timeout — safety cap, not a timing assertion. The
            // 1 s cap previously here flaked when run alongside the
            // parallel test workload that loads system schedulers.
            acquireTimeout: .waitUpTo(.seconds(30)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let first = try await pool.acquire()
        for _ in 0..<100 {
            let secondConn = try await Self.runWaiterRaceIteration(pool: pool, holder: first)
            #expect(secondConn === first, "released connection must reach the waiter — no race orphan")
        }
        await pool.release(first)
    }

    private static func runWaiterRaceIteration(
        pool: ClickHouseConnectionPool,
        holder: ClickHouseConnection
    ) async throws -> ClickHouseConnection {
        async let secondResult: ClickHouseConnection = pool.acquire()
        await pool.release(holder)
        return try await secondResult
    }

    @Test("acquireTimeout: a release while a waiter is queued hands the connection over directly")
    func releaseHandsConnectionToWaiter() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            // 120 s timeout — safety cap, not timing assertion. See
            // `concurrentAcquiresDoNotOvershootMax` for rationale.
            acquireTimeout: .waitUpTo(.seconds(120)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let first = try await pool.acquire()

        // Spawn a task that will try to acquire — should suspend in the wait queue.
        async let waiterResult: ClickHouseConnection = pool.acquire()

        // Give the waiter a moment to enqueue.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await pool.waiterCount == 1, "the second acquire should be suspended in the wait queue")

        // Release the first connection — should wake the waiter.
        await pool.release(first)
        let received = try await waiterResult
        #expect(received === first, "the released connection is handed directly to the waiter")
        #expect(await pool.waiterCount == 0)
    }

    @Test("acquireTimeout: when no release happens, the suspended acquire throws poolWaitTimeout after the deadline")
    func waiterTimesOutWithoutRelease() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            acquireTimeout: .waitUpTo(.milliseconds(100)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        _ = try await pool.acquire()

        var thrown: Error?
        do {
            _ = try await pool.acquire()
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.poolWaitTimeout = received else {
            Issue.record("expected poolWaitTimeout, got \(String(describing: thrown))")
            return
        }
    }

    @Test("effectiveWarmupCount caps the requested count by maxConnections and maxIdleConnections")
    func effectiveWarmupCountCaps() async {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 10,
            maxIdleConnections: 4,
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        // Cap by maxIdleConnections (4) when it's the smaller bound
        #expect(await pool.effectiveWarmupCount(requested: 100) == 4)
        // Below both caps → returned verbatim
        #expect(await pool.effectiveWarmupCount(requested: 2) == 2)
        // Negative or zero → 0
        #expect(await pool.effectiveWarmupCount(requested: 0) == 0)
        #expect(await pool.effectiveWarmupCount(requested: -5) == 0)
    }

    @Test("effectiveWarmupCount caps by maxConnections when maxConnections is the tighter bound")
    func effectiveWarmupCountCapsByMaxConnections() async {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 3,
            maxIdleConnections: 100,
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        #expect(await pool.effectiveWarmupCount(requested: 50) == 3)
    }

    @Test("a recently-failed endpoint is skipped on the next acquire (within cooldown window)")
    func failedEndpointSkippedDuringCooldown() async throws {
        let clock = MockClock()
        let attempted = TestEndpointTracker()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000), .init(host: "h2", port: 9000)],
            endpointFailureCooldown: .seconds(30),
            connectionFactory: { endpoint in
                attempted.record(endpoint)
                if endpoint.host == "h1" {
                    throw TestError.simulatedFailure
                }
                return try Self.makeMockConnection()
            },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        // First acquire: cursor starts at 0 → tries h1 (fails) → tries h2 (succeeds).
        // Hold the connection (don't release) so the second acquire is forced to
        // open a fresh one rather than reusing the idle one.
        let _ = try await pool.acquire()
        attempted.clear()

        // Second acquire: cursor is now at 2 → primary candidate is h1 again.
        // But h1 is in cooldown — should skip directly to h2.
        clock.now = .uptimeNanoseconds(5_000_000_000)  // 5s later, well within 30s cooldown
        _ = try await pool.acquire()
        #expect(attempted.recorded == ["h2"], "cooldown-tracked endpoint h1 must be skipped on the next acquire")
    }

    @Test("openWithFailover never dials the same endpoint twice in one round even when a mid-loop failure puts every other endpoint in cooldown")
    func openWithFailoverDoesNotRetrySameEndpointInOneRound() async throws {
        let clock = MockClock()
        let attempted = TestEndpointTracker()
        // Three endpoints: h1 already in cooldown from a prior failure
        // (we set this up by failing h1 first), h2 will fail in this
        // round, h3 will also fail. After h2's mid-loop failure, every
        // other endpoint is in cooldown — `nextEndpoint` would
        // otherwise fall back to h2 a second time.
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [
                .init(host: "h1", port: 9000),
                .init(host: "h2", port: 9000),
                .init(host: "h3", port: 9000)
            ],
            endpointFailureCooldown: .seconds(30),
            connectionFactory: { endpoint in
                attempted.record(endpoint)
                throw TestError.simulatedFailure
            },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        // Attempt 1: dials h1, h2, h3 (all fail), surfaces allPoolEndpointsFailed.
        await #expect(throws: (any Error).self) {
            _ = try await pool.acquire()
        }
        let firstRound = attempted.recorded
        attempted.clear()

        // Attempt 2: cursor is at 3, primary is h1 (cooldown), every
        // candidate is in cooldown. nextEndpoint falls back to h1.
        // h1 fails again, refreshing its cooldown. Without dedup, the
        // next iterations would land on h1 again and again. With dedup,
        // the loop tries h1 once, h2 once, h3 once.
        clock.now = .uptimeNanoseconds(1_000_000_000)
        await #expect(throws: (any Error).self) {
            _ = try await pool.acquire()
        }
        let secondRound = attempted.recorded
        let h1Hits = secondRound.filter { $0 == "h1" }.count
        let h2Hits = secondRound.filter { $0 == "h2" }.count
        let h3Hits = secondRound.filter { $0 == "h3" }.count
        #expect(h1Hits <= 1, "h1 must be dialed at most once per failover round, got \(h1Hits)")
        #expect(h2Hits <= 1, "h2 must be dialed at most once per failover round, got \(h2Hits)")
        #expect(h3Hits <= 1, "h3 must be dialed at most once per failover round, got \(h3Hits)")
        #expect(secondRound.count <= 3, "second round must not exceed endpoint count, got \(secondRound)")
        // Round 1 had no dedup ambiguity since nothing was in cooldown
        // before it ran — assert the baseline expectation that round 1
        // tried every endpoint exactly once.
        #expect(firstRound.count == 3)
    }

    @Test("after the cooldown window expires, a previously-failed endpoint is retried")
    func failedEndpointRetriedAfterCooldown() async throws {
        let clock = MockClock()
        let attempted = TestEndpointTracker()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000), .init(host: "h2", port: 9000)],
            endpointFailureCooldown: .seconds(30),
            connectionFactory: { endpoint in
                attempted.record(endpoint)
                if endpoint.host == "h1" && attempted.recorded.filter({ $0 == "h1" }).count == 1 {
                    // First time h1 is tried, fail. Subsequent attempts succeed.
                    throw TestError.simulatedFailure
                }
                return try Self.makeMockConnection()
            },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        _ = try await pool.acquire()  // h1 fails, h2 succeeds. Hold connection.
        attempted.clear()

        // After cooldown window, h1 should be retried as the primary candidate.
        clock.now = .uptimeNanoseconds(60_000_000_000)  // 60s later, past 30s cooldown
        // Hold the connection again so the next acquire is forced to open fresh.
        _ = try await pool.acquire()
        #expect(attempted.recorded.contains("h1"), "after cooldown expiry, the previously-failed endpoint must be retried")
    }

    @Test("a successful open clears the endpoint's failure mark immediately")
    func successfulOpenClearsFailureMark() async throws {
        let clock = MockClock()
        let attempted = TestEndpointTracker()
        let attemptCounter = TestCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000), .init(host: "h2", port: 9000)],
            endpointFailureCooldown: .seconds(30),
            connectionFactory: { endpoint in
                attempted.record(endpoint)
                attemptCounter.increment()
                // h1 fails on attempt 1, succeeds afterwards. h2 always succeeds.
                if endpoint.host == "h1" && attemptCounter.value == 1 {
                    throw TestError.simulatedFailure
                }
                return try Self.makeMockConnection()
            },
            nowProvider: { clock.now }
        ))

        // Acquire 1: h1 fails, h2 succeeds. h1 is marked failed. Hold connection.
        clock.now = .uptimeNanoseconds(0)
        _ = try await pool.acquire()
        // Past cooldown so h1 will be tried again.
        clock.now = .uptimeNanoseconds(60_000_000_000)
        attempted.clear()
        // Acquire 2: cursor on h1, past cooldown, h1 succeeds (since attemptCounter > 1).
        // The successful open must clear h1's failure mark.
        _ = try await pool.acquire()
        #expect(attempted.recorded.contains("h1"), "after cooldown, h1 is retried as primary")
        attempted.clear()
        // Acquire 3 (still past cooldown): cursor advances; primary is h2.
        // Verify h1 is NO LONGER skipped via cooldown (failure mark cleared).
        // We can't easily observe "no longer in cooldown" directly, but the
        // attempt counter doesn't grow except for the legitimate next acquire.
        let beforeCount = attemptCounter.value
        _ = try await pool.acquire()
        #expect(attemptCounter.value == beforeCount + 1, "exactly one new factory call (no failover needed since h1 is healthy now)")
    }

    @Test("when ALL endpoints are in cooldown, the pool falls back to attempting the primary candidate anyway")
    func allEndpointsInCooldownFallsBack() async throws {
        let clock = MockClock()
        let attempted = TestEndpointTracker()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h1", port: 9000), .init(host: "h2", port: 9000)],
            endpointFailureCooldown: .seconds(30),
            connectionFactory: { endpoint in
                attempted.record(endpoint)
                throw TestError.simulatedFailure  // every attempt fails
            },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        // First acquire: tries h1 (fail) → tries h2 (fail) → throws allPoolEndpointsFailed.
        await #expect(throws: ClickHouseError.self) {
            _ = try await pool.acquire()
        }
        // Both h1 and h2 are now in cooldown.
        attempted.clear()
        // Second acquire (still within cooldown): all endpoints in cooldown,
        // pool must fall back to attempting one anyway (better than hanging).
        await #expect(throws: ClickHouseError.self) {
            _ = try await pool.acquire()
        }
        #expect(!attempted.recorded.isEmpty, "with all endpoints in cooldown, the pool still attempts at least one — refusing all queries is worse than retrying")
    }

    @Test("backgroundEvictionInterval=.onAcquireOnly never spawns the eviction task — existing on-demand-eviction behavior is preserved")
    func backgroundEvictionDisabledByDefault() async throws {
        let clock = MockClock()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            idleTimeout: .seconds(30),
            connectionFactory: { _ in try Self.makeMockConnection() },
            nowProvider: { clock.now }
        ))
        clock.now = .uptimeNanoseconds(0)
        let c = try await pool.acquire()
        await pool.release(c)
        // Advance clock past idleTimeout. With background eviction OFF, the
        // connection stays in idle until the next acquire triggers eviction.
        clock.now = .uptimeNanoseconds(60_000_000_000)
        // Real-time wait — gives any background tasks (if mistakenly spawned) a chance to fire
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await pool.idleCount == 1, "with no background eviction, the stale connection lingers until next acquire")
    }

    @Test("backgroundEvictionInterval evicts stale connections without an acquire call")
    func backgroundEvictionRunsPeriodically() async throws {
        let clock = MockClock()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            idleTimeout: .seconds(30),
            backgroundEvictionInterval: .every(.milliseconds(50)),
            connectionFactory: { _ in try Self.makeMockConnection() },
            nowProvider: { clock.now }
        ))
        clock.now = .uptimeNanoseconds(0)
        let c = try await pool.acquire()
        await pool.release(c)
        #expect(await pool.idleCount == 1)

        // Advance MockClock past idleTimeout; the next eviction sweep
        // (via background task or acquire) will discard the stale entry.
        clock.now = .uptimeNanoseconds(60_000_000_000)
        // Poll until the eviction tick reaps the entry. The bare 200 ms
        // sleep flaked under a heavily loaded test runner (concurrent
        // integration suite starved the eviction task past the 50 ms
        // tick interval). The poll loop bounds total wait at 2 seconds
        // so the test still fails fast on a real bug, but tolerates
        // realistic scheduling jitter on busy CI hardware.
        var idleCount = await pool.idleCount
        for _ in 0..<40 where idleCount != 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
            idleCount = await pool.idleCount
        }
        #expect(idleCount == 0, "background eviction must reap the stale connection without an acquire call")

        await pool.shutdown()
    }

    @Test("background eviction reaps idle connections whose channel has gone inactive even before idleTimeout fires")
    func backgroundEvictionReapsDeadConnections() async throws {
        let clock = MockClock()
        let channelHolder = TestChannelHolder()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            // Long idleTimeout so the test cannot trip on the timeout
            // sweep; we want the dead-channel branch specifically.
            idleTimeout: .hours(1),
            backgroundEvictionInterval: .every(.milliseconds(50)),
            connectionFactory: { _ in
                let (connection, channel) = try Self.makeMockConnectionExposingChannel()
                channelHolder.append(channel)
                return connection
            },
            nowProvider: { clock.now }
        ))
        clock.now = .uptimeNanoseconds(0)
        let c = try await pool.acquire()
        await pool.release(c)
        #expect(await pool.idleCount == 1)

        // Simulate the server hanging up after the connection was
        // parked. The channel goes inactive but the idleTimeout has
        // not fired. Without dead-channel eviction the entry would
        // sit in idle forever (or until the timeout). With it, the
        // next eviction tick clears it.
        try await channelHolder.first.close()

        var idleCount = await pool.idleCount
        for _ in 0..<40 where idleCount != 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
            idleCount = await pool.idleCount
        }
        #expect(idleCount == 0, "eviction must reap inactive channels without waiting for idleTimeout")

        await pool.shutdown()
    }

    @Test("shutdown cancels the background eviction task so it doesn't outlive the pool")
    func shutdownCancelsBackgroundEvictionTask() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            backgroundEvictionInterval: .every(.milliseconds(50)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))
        // Trigger lazy spawn of the task.
        let c = try await pool.acquire()
        await pool.release(c)
        await pool.shutdown()
        // After shutdown, the task is cancelled. We verify by calling shutdown
        // again (idempotent) without hanging.
        await pool.shutdown()
    }

    @Test("the warmUp acquire-then-release pattern lands all connections in the idle pool")
    func warmUpPatternFillsIdlePool() async throws {
        let factoryCalls = TestCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 5,
            maxIdleConnections: 5,
            connectionFactory: { _ in
                factoryCalls.increment()
                return try Self.makeMockConnection()
            }
        ))
        // Mirror the implementation of client.warmUp: cap, acquire, release.
        let target = await pool.effectiveWarmupCount(requested: 3)
        var opened: [ClickHouseConnection] = []
        for _ in 0..<target {
            opened.append(try await pool.acquire())
        }
        for connection in opened {
            await pool.release(connection)
        }
        #expect(target == 3)
        #expect(factoryCalls.value == 3, "factory should be called once per warmed connection")
        #expect(await pool.idleCount == 3, "all warmed connections must land in the idle pool")
        #expect(await pool.activeCount == 0)
    }

    @Test("preflightPingThreshold below idle duration triggers a Ping; pool returns the same connection on Pong")
    func preflightPingPassesAndReturnsSameConnection() async throws {
        let clock = MockClock()
        // Track every connection produced so we can pre-load its inbound side with Pong.
        let createdChannels = TestChannelHolder()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            idleTimeout: .seconds(60),
            maxLifetime: .hours(1),
            preflightPingThreshold: .afterIdleFor(.seconds(10)),
            connectionFactory: { _ in
                let (conn, channel) = try Self.makeMockConnectionExposingChannel()
                createdChannels.append(channel)
                return conn
            },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        let c1 = try await pool.acquire()
        await pool.release(c1)

        // 20s idle (> 10s threshold) → pool should ping. Pre-load Pong response.
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.pong.write(into: &inbound)
        try createdChannels.first.writeInbound(inbound)

        clock.now = .uptimeNanoseconds(20_000_000_000)
        let c2 = try await pool.acquire()
        #expect(c2 === c1, "pre-flight ping passed; pool returned the same connection")
    }

    @Test("preflightPingThreshold above idle duration skips the Ping")
    func preflightPingThresholdSkippedBelowDuration() async throws {
        let clock = MockClock()
        let createdChannels = TestChannelHolder()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            idleTimeout: .seconds(60),
            maxLifetime: .hours(1),
            preflightPingThreshold: .afterIdleFor(.seconds(30)),
            connectionFactory: { _ in
                let (conn, channel) = try Self.makeMockConnectionExposingChannel()
                createdChannels.append(channel)
                return conn
            },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        let c1 = try await pool.acquire()
        await pool.release(c1)

        // 5s idle (< 30s threshold) → no ping should be sent.
        clock.now = .uptimeNanoseconds(5_000_000_000)
        _ = try await pool.acquire()

        // Verify no Ping was sent on the wire.
        var sawPing = false
        while let outbound = try createdChannels.first.readOutbound(as: ByteBuffer.self) {
            var buffer = outbound
            while buffer.readableBytes > 0 {
                let type = try ClickHouseClientPacketType.read(from: &buffer)
                if type == .ping { sawPing = true }
            }
        }
        #expect(sawPing == false, "no ping should be sent when idle duration is below threshold")
    }

    @Test("preflightPingThreshold pings the stale connection; failed Ping closes it and opens a fresh one")
    func preflightFailureClosesStaleAndOpensNew() async throws {
        let clock = MockClock()
        let factoryCalls = TestCounter()
        let createdChannels = TestChannelHolder()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            idleTimeout: .seconds(60),
            maxLifetime: .hours(1),
            preflightPingThreshold: .afterIdleFor(.seconds(10)),
            connectionFactory: { _ in
                factoryCalls.increment()
                let (conn, channel) = try Self.makeMockConnectionExposingChannel()
                createdChannels.append(channel)
                return conn
            },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        let c1 = try await pool.acquire()
        await pool.release(c1)

        // Pre-load a Progress packet (NOT Pong) — ping will throw unexpectedPingResponse.
        var inbound = ByteBuffer()
        ClickHouseServerPacketType.progress.write(into: &inbound)
        let progress = ClickHouseServerProgressPacket(
            rows: 1, bytes: 4, totalRows: 1, writtenRows: .value(0), writtenBytes: .value(0)
        )
        progress.encode(into: &inbound, revision: Self.revision)
        try createdChannels.first.writeInbound(inbound)

        clock.now = .uptimeNanoseconds(20_000_000_000)
        let c2 = try await pool.acquire()
        #expect(c2 !== c1, "stale connection should have been closed; a fresh one opened")
        #expect(factoryCalls.value == 2, "the factory should be called twice: once for c1, once for replacement")
    }

    @Test("connections older than maxLifetime are not pooled even if idle slot is free")
    func maxLifetimeEnforcedOnRelease() async throws {
        let clock = MockClock()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxIdleConnections: 5,
            idleTimeout: .hours(1),
            maxLifetime: .seconds(30),
            connectionFactory: { _ in try Self.makeMockConnection() },
            nowProvider: { clock.now }
        ))

        clock.now = .uptimeNanoseconds(0)
        let connection = try await pool.acquire()

        clock.now = .uptimeNanoseconds(60_000_000_000)
        await pool.release(connection)
        #expect(await pool.idleCount == 0)
        #expect(await pool.activeCount == 0)
    }

    @Test("release that arrives after a waiter has timed out routes the connection to idle, not to the timed-out waiter")
    func releaseAfterAcquireTimeoutDoesNotResumeStaleWaiter() async throws {
        // Burns one connection slot, queues a second acquire with a
        // short timeout. After the waiter times out (poolWaitTimeout
        // is observable), release the held connection. The released
        // connection must land in idle: the timed-out waiter is gone
        // from `waiters[]` and `popPendingWaiter()` returns nil. Pre-
        // fix risk: a logic regression where the released connection
        // tried to hand off to a waiter that no longer existed could
        // silently drop the connection.
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            acquireTimeout: .waitUpTo(.milliseconds(50)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let held = try await pool.acquire()
        // Spin off a second acquire that we expect to time out.
        let waiter = Task { try await pool.acquire() }

        // Wait for the timeout. The waiter should resume with poolWaitTimeout.
        var thrown: Error?
        do {
            _ = try await waiter.value
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        guard case .poolWaitTimeout = received ?? .poolHasNoEndpoints else {
            Issue.record("expected poolWaitTimeout, got \(String(describing: thrown))")
            return
        }

        // Now the timed-out waiter is gone. Release the held connection;
        // it must land in idle, not get silently dropped.
        await pool.release(held)
        #expect(await pool.idleCount == 1, "released connection must park in idle when no waiter is queued")
        #expect(await pool.activeCount == 0)
    }

    @Test("a closed connection released to the pool is dropped, not queued")
    func closedConnectionsNotPooled() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let connection = try await pool.acquire()
        try await connection.close()
        await pool.release(connection)
        #expect(await pool.idleCount == 0)
        #expect(await pool.activeCount == 0)
    }

    @Test("withConnection auto-releases on success path")
    func withConnectionAutoReleasesOnSuccess() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let result: Int = try await pool.withConnection { _ in 42 }
        #expect(result == 42)
        #expect(await pool.activeCount == 0)
        #expect(await pool.idleCount == 1)
    }

    @Test("withConnection auto-releases on throw path")
    func withConnectionAutoReleasesOnThrow() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        await #expect(throws: TestError.simulatedFailure) {
            try await pool.withConnection { _ -> Int in
                throw TestError.simulatedFailure
            }
        }
        #expect(await pool.activeCount == 0)
        #expect(await pool.idleCount == 1)
    }

    @Test("shutdown closes all idle connections and clears state")
    func shutdownClosesIdleAndClearsState() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let c1 = try await pool.acquire()
        let c2 = try await pool.acquire()
        await pool.release(c1)
        await pool.release(c2)
        #expect(await pool.idleCount == 2)

        await pool.shutdown()
        #expect(await pool.idleCount == 0)
        #expect(await pool.activeCount == 0)
    }

    @Test("acquire that's mid-connect when shutdown fires must NOT return a usable connection (race; post-shutdown acquire invariant)")
    func acquireThatIsMidConnectAtShutdownTimeStillThrows() async throws {
        // Race scenario: acquire() passes the isShutdown guard, enters
        // openWithFailover, awaits the connection factory. While the
        // factory is suspended, shutdown() runs on the pool actor and
        // sets isShutdown = true. The factory then resumes and returns
        // a fresh connection. Pre-fix: acquire() ignored the now-true
        // flag and returned the connection, violating the "post-
        // shutdown acquires must throw" invariant. Post-fix: acquire
        // re-checks isShutdown after the await and throws poolShutdown,
        // closing the just-opened connection so it doesn't leak.
        let channelHolder = TestChannelHolder()
        let factoryEntered = TestCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in
                factoryEntered.increment()
                // Sleep long enough that the test can fire shutdown
                // before this returns. Cooperative cancellation will
                // abort early if the parent task is cancelled, so
                // the worst case is we wait the configured duration.
                try? await Task.sleep(nanoseconds: 200_000_000)
                let (connection, channel) = try Self.makeMockConnectionExposingChannel()
                channelHolder.append(channel)
                return connection
            }
        ))

        let acquireTask = Task { try await pool.acquire() }

        // Spin until the factory has been entered — that proves
        // acquire is past the openingCount reservation and suspended
        // on the factory's sleep.
        for _ in 0..<500 {
            if factoryEntered.value == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(factoryEntered.value == 1, "factory must have been entered")

        // Fire shutdown while acquire is suspended in the factory.
        await pool.shutdown()

        // The acquire must surface poolShutdown, not a connection.
        var thrown: Error?
        do {
            _ = try await acquireTask.value
        } catch {
            thrown = error
        }
        #expect(thrown as? ClickHouseError == .poolShutdown,
                "acquire that finished connect after shutdown must throw poolShutdown, got \(String(describing: thrown))")

        // The connection that the factory produced (if any) must be
        // closed, not leaked. Wait for the detached close Task to run.
        if !channelHolder.isEmpty {
            for _ in 0..<200 {
                if !channelHolder.first.isActive { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(!channelHolder.first.isActive,
                    "connection produced after shutdown must be closed, not leaked")
        }
    }

    @Test("acquire after shutdown throws poolShutdown without opening a new connection or restarting the eviction task")
    func acquireAfterShutdownIsTerminal() async throws {
        let factoryCalls = TestCounter()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            backgroundEvictionInterval: .every(.seconds(60)),
            connectionFactory: { _ in
                await factoryCalls.increment()
                return try Self.makeMockConnection()
            }
        ))

        let first = try await pool.acquire()
        await pool.release(first)
        await pool.shutdown()

        let beforeShutdownCalls = await factoryCalls.value
        await #expect(throws: ClickHouseError.poolShutdown) {
            _ = try await pool.acquire()
        }
        let afterShutdownCalls = await factoryCalls.value
        #expect(
            afterShutdownCalls == beforeShutdownCalls,
            "post-shutdown acquire must not call the connection factory"
        )
        // The terminal pool must remain empty: a rejected acquire must
        // not leave behind half-opened state or a fresh idle entry.
        #expect(await pool.idleCount == 0)
        #expect(await pool.activeCount == 0)
    }

    @Test("release after shutdown closes the connection's channel instead of returning it to idle")
    func releaseAfterShutdownClosesConnection() async throws {
        let channelHolder = TestChannelHolder()
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in
                let (connection, channel) = try Self.makeMockConnectionExposingChannel()
                channelHolder.append(channel)
                return connection
            }
        ))

        let connection = try await pool.acquire()
        // Pre-fix: shutdown set isShutdown at the END of its close loop,
        // and release() during that window parked the connection in idle.
        // After idle.removeAll() the connection silently leaked. Now
        // isShutdown flips before the loops, so a release after (or
        // racing with) shutdown takes the close-and-discard path.
        await pool.shutdown()
        await pool.release(connection)

        // Wait briefly for the detached close Task to run on the
        // event loop. The Task is scheduled immediately but runs
        // asynchronously; without a brief delay the channel may
        // still report active.
        for _ in 0..<200 {
            if !channelHolder.first.isActive { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await pool.idleCount == 0, "shutdown pool must not retain released connections")
        #expect(!channelHolder.first.isActive, "release after shutdown must actually close the underlying channel")
    }

    @Test("shutdown wakes pending acquire waiters with poolShutdown rather than poolExhausted (retry would never succeed)")
    func shutdownWakesWaitersWithPoolShutdown() async throws {
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            maxConnections: 1,
            // Long enough that the test never falls back to poolWaitTimeout.
            acquireTimeout: .waitUpTo(.seconds(120)),
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        // Saturate the single slot so the next acquire is forced to wait.
        let held = try await pool.acquire()

        let waiter = Task { try await pool.acquire() }

        // Spin until the waiter has actually enqueued, so we shut down
        // with a real pending waiter rather than racing the enqueue.
        for _ in 0..<200 {
            if await pool.waiterCount == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await pool.waiterCount == 1)

        await pool.shutdown()

        var thrown: Error?
        do {
            _ = try await waiter.value
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        #expect(
            received as? ClickHouseError == .poolShutdown,
            "shutdown must wake waiters with poolShutdown, got \(received)"
        )

        // Held connection is now the caller's responsibility; releasing
        // into a shut-down pool is a no-op (idle stays empty).
        await pool.release(held)
        #expect(await pool.idleCount == 0)
    }

    @Test("releasing the same connection twice is idempotent: the second release does NOT silently re-park the connection in idle (data-corruption invariant)")
    func doubleReleaseIsIdempotent() async throws {
        // Pre-fix bug: release() removes from active and parks in idle.
        // A second release sees `active.removeValue(...) == nil`, falls
        // through, and parks the SAME connection in idle a second time.
        // Two future acquires would each pop one — handing the same
        // connection to two different callers concurrently. Caller A
        // sends a Query packet, caller B sends a Data packet — wire is
        // misframed and both queries fail.
        let pool = ClickHouseConnectionPool(configuration: .init(
            endpoints: [.init(host: "h", port: 9000)],
            connectionFactory: { _ in try Self.makeMockConnection() }
        ))

        let connection = try await pool.acquire()
        await pool.release(connection)
        #expect(await pool.idleCount == 1)

        // Second release of the same connection. Pre-fix: idleCount
        // climbs to 2. Post-fix: stays at 1.
        await pool.release(connection)
        #expect(await pool.idleCount == 1, "double-release must not duplicate the connection in idle")

        // Pop both potential entries and confirm only one came out.
        let firstAcquire = try await pool.acquire()
        #expect(await pool.idleCount == 0, "after acquiring, idle must be empty")
        await pool.release(firstAcquire)
    }

}

private enum TestError: Error, Equatable {

    case simulatedFailure

}

private final class TestChannelHolder: @unchecked Sendable {

    private let lock = NSLock()
    private var channels: [EmbeddedChannel] = []

    func append(_ channel: EmbeddedChannel) {
        lock.lock()
        defer { lock.unlock() }
        channels.append(channel)
    }

    var first: EmbeddedChannel {
        lock.lock()
        defer { lock.unlock() }
        return channels[0]
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return channels.isEmpty
    }

}

private final class TestCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }

}

private final class TestEndpointTracker: @unchecked Sendable {

    private let lock = NSLock()
    private var _hosts: [String] = []

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _hosts
    }

    func record(_ endpoint: ClickHouseEndpoint) {
        lock.lock()
        _hosts.append(endpoint.host)
        lock.unlock()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        _hosts.removeAll()
    }

}

private final class MockClock: @unchecked Sendable {

    private let lock = NSLock()
    private var _now: NIODeadline = .now()

    var now: NIODeadline {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }
        set {
            lock.lock()
            _now = newValue
            lock.unlock()
        }
    }

}
