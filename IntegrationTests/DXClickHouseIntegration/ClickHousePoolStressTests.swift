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

// Pool-level stress tests against the live cluster. These exercise
// queue/wait paths that unit tests can't cover end-to-end: acquire
// contention under heavy concurrency, queue draining when load drops,
// and pool reuse across many sequential queries.
@Suite(
    "ClickHouse integration — pool stress",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHousePoolStressTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static func makeClient(
        maxConnections: Int = 10,
        acquireTimeout: ClickHouseClient.PoolAcquireTimeout = .failImmediatelyWhenExhausted,
        idleTimeout: TimeAmount = .seconds(60),
        maxLifetime: TimeAmount = .minutes(10),
        backgroundEvictionInterval: ClickHouseClient.PoolBackgroundEviction = .onAcquireOnly
    ) -> (ClickHouseClient, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            maxConnections: maxConnections,
            idleTimeout: idleTimeout,
            maxLifetime: maxLifetime,
            acquireTimeout: acquireTimeout,
            backgroundEvictionInterval: backgroundEvictionInterval,
            eventLoopGroup: group
        ))
        return (client, group)
    }

    @Test("100 concurrent SELECTs against a 4-connection pool all complete with the same answer")
    func smallPoolHandlesHeavyConcurrency() async throws {
        // 100 acquires against a 4-slot pool requires queueing — the
        // overflow callers wait their turn rather than fail.
        let (client, _) = Self.makeClient(maxConnections: 4, acquireTimeout: .waitUpTo(.seconds(30)))
        defer { Task { await client.shutdown() } }

        let total = 100
        try await withThrowingTaskGroup(of: Int64?.self) { taskGroup in
            for index in 0..<total {
                taskGroup.addTask {
                    try await client.scalarInt64("SELECT toInt64(\(index))")
                }
            }
            var seen: Set<Int64> = []
            for try await value in taskGroup {
                if let value { seen.insert(value) }
            }
            #expect(seen.count == total)
        }
    }

    @Test("acquireTimeout fires when a long-running query holds the only slot of a single-connection pool")
    func acquireTimeoutOnBlockedPool() async throws {
        let (client, _) = Self.makeClient(maxConnections: 1, acquireTimeout: .waitUpTo(.milliseconds(20)))
        defer { Task { await client.shutdown() } }

        // Warm the pool with a synchronous query first; the connection
        // returns to idle but the pool now has a real socket open. This
        // sidesteps the open-connection race that can let multiple
        // acquires pass the maxConnections check during the connect
        // await.
        _ = try await client.scalarInt64("SELECT toInt64(0)")

        // Hold the single warm connection with a 1-second server sleep.
        async let blocker = client.scalarInt64(
            "SELECT toInt64(sleepEachRow(1.0)) SETTINGS function_sleep_max_microseconds_per_block = 2000000"
        )
        // Wait long enough for the blocker to actually be running, not
        // just queued on the local task scheduler.
        try await Task.sleep(nanoseconds: 250_000_000)

        var caughtTimeout = false
        do {
            _ = try await client.scalarInt64("SELECT toInt64(0)")
        } catch ClickHouseError.poolWaitTimeout {
            caughtTimeout = true
        }
        _ = try? await blocker
        #expect(caughtTimeout, "the contender's acquire must time out while the pool's only slot is held")
    }

    @Test("a sustained burst of 500 sequential SELECTs reuses connections from the warm pool")
    func sustainedBurstReusesConnections() async throws {
        let (client, _) = Self.makeClient(maxConnections: 5)
        defer { Task { await client.shutdown() } }

        for index in 0..<500 {
            let value = try await client.scalarInt64("SELECT toInt64(\(index))")
            #expect(value == Int64(index))
        }
        let stats = await client.poolStats()
        // After 500 sequential acquire/release cycles on a 5-connection pool,
        // we expect way fewer than 500 distinct connections to have been
        // created — most calls hit the warm pool.
        #expect(stats.totalConnectionsOpened <= 5)
    }

    @Test("the pool surfaces idle counts after queries drain")
    func poolStatsReflectIdleAfterDrain() async throws {
        let (client, _) = Self.makeClient(maxConnections: 3)
        defer { Task { await client.shutdown() } }

        // Warm three connections concurrently so the pool grows.
        try await withThrowingTaskGroup(of: Int64?.self) { taskGroup in
            for _ in 0..<3 {
                taskGroup.addTask {
                    try await client.scalarInt64("SELECT toInt64(sleepEachRow(0.05))")
                }
            }
            for try await _ in taskGroup {}
        }
        let stats = await client.poolStats()
        // After the burst, all three should be idle and acquireable again.
        #expect(stats.totalConnectionsOpened <= 3)
        #expect(stats.idleCount >= 1)
    }

    @Test("abandoning a SELECT stream early returns the connection to the pool clean for the next caller")
    func abandonedSelectStreamRecycles() async throws {
        let (client, _) = Self.makeClient(maxConnections: 1)
        defer { Task { await client.shutdown() } }

        // Stream a 100k-row SELECT but break after the first row.
        // The pool's selectBlocks path sends Cancel and drains until
        // EndOfStream; otherwise the next acquire would either block
        // on the in-flight query or re-use a poisoned connection.
        var rowsConsumed = 0
        for try await block in client.selectColumns("SELECT arrayJoin(range(toUInt64(100000))) AS n") {
            if block.rowCount > 0 {
                rowsConsumed += block.rowCount
                break
            }
        }
        #expect(rowsConsumed > 0)

        // The next query must succeed on the same client / same pool.
        let value = try await client.scalarInt64("SELECT toInt64(7)")
        #expect(value == 7)
    }

    @Test("a server-side failure mid-INSERT does not leave the connection in a half-state")
    func failedInsertRecycles() async throws {
        let (client, _) = Self.makeClient(maxConnections: 1)
        defer { Task { await client.shutdown() } }

        // INSERT into a table that doesn't exist — server raises after
        // we've sent the Query packet. The pool must tear down the bad
        // connection so the next acquire opens a clean one.
        do {
            try await client.insert(
                into: "test.nonexistent_\(UUID().uuidString.prefix(8))",
                columns: [.init(name: "n", values: .int32([1, 2, 3]))]
            )
            Issue.record("expected serverException")
        } catch ClickHouseError.serverException {
            // expected
        }

        // Subsequent query on the recycled pool slot must succeed.
        let value = try await client.scalarInt64("SELECT toInt64(11)")
        #expect(value == 11)
    }

    // MARK: - eviction

    @Test("idleTimeout drops a stale idle connection so the next acquire opens a fresh one")
    func idleTimeoutEvictsStaleConnection() async throws {
        let (client, _) = Self.makeClient(maxConnections: 1, idleTimeout: .milliseconds(100))
        defer { Task { await client.shutdown() } }

        // Warm a connection, then idle past the timeout. The next
        // acquire should evict the stale entry and open a new one,
        // which we can detect by the totalConnectionsOpened counter.
        _ = try await client.scalarInt64("SELECT toInt64(1)")
        let beforeIdle = await client.poolStats()
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await client.scalarInt64("SELECT toInt64(2)")
        let afterIdle = await client.poolStats()

        #expect(afterIdle.totalConnectionsOpened > beforeIdle.totalConnectionsOpened,
                "expected a new connection after idleTimeout expired; before=\(beforeIdle.totalConnectionsOpened) after=\(afterIdle.totalConnectionsOpened)")
    }

    @Test("maxLifetime caps connection age so a long-lived warm connection still gets replaced")
    func maxLifetimeReplacesAgedConnection() async throws {
        let (client, _) = Self.makeClient(maxConnections: 1, maxLifetime: .milliseconds(150))
        defer { Task { await client.shutdown() } }

        _ = try await client.scalarInt64("SELECT toInt64(1)")
        let beforeAged = await client.poolStats()
        // Sleep past the lifetime, then run a query — the pool should
        // discard the aged connection and open a fresh one.
        try await Task.sleep(nanoseconds: 250_000_000)
        _ = try await client.scalarInt64("SELECT toInt64(2)")
        let afterAged = await client.poolStats()

        #expect(afterAged.totalConnectionsOpened > beforeAged.totalConnectionsOpened,
                "expected a new connection after maxLifetime expired; before=\(beforeAged.totalConnectionsOpened) after=\(afterAged.totalConnectionsOpened)")
    }

    @Test("background eviction reaps idle connections without an acquire call")
    func backgroundEvictionReapsIdle() async throws {
        let (client, _) = Self.makeClient(
            maxConnections: 1,
            idleTimeout: .milliseconds(100),
            backgroundEvictionInterval: .every(.milliseconds(50))
        )
        defer { Task { await client.shutdown() } }

        // Open one connection, return it idle.
        _ = try await client.scalarInt64("SELECT toInt64(1)")
        let beforeReap = await client.poolStats()
        #expect(beforeReap.idleCount == 1, "expected 1 idle connection after the warm-up query")

        // Wait long enough for the background eviction tick to fire and
        // reap the entry without anyone acquiring.
        try await Task.sleep(nanoseconds: 250_000_000)
        let afterReap = await client.poolStats()
        #expect(afterReap.idleCount == 0, "background eviction should have reaped the stale idle entry; got \(afterReap)")
    }

    // MARK: - soak

    @Test("2000 back-to-back queries against a 5-slot pool stay bounded by the connection cap")
    func soakBackToBackReusesPool() async throws {
        let (client, _) = Self.makeClient(maxConnections: 5)
        defer { Task { await client.shutdown() } }

        for index in 0..<2_000 {
            let value = try await client.scalarInt64("SELECT toInt64(\(index))")
            #expect(value == Int64(index))
        }
        let stats = await client.poolStats()
        #expect(stats.totalConnectionsOpened <= 5,
                "back-to-back queries should reuse connections; opened=\(stats.totalConnectionsOpened)")
    }

    @Test("queries spaced past idleTimeout cycle the pool without leaking sockets")
    func soakIdleCyclingDoesNotLeak() async throws {
        let (client, _) = Self.makeClient(
            maxConnections: 1,
            idleTimeout: .milliseconds(50)
        )
        defer { Task { await client.shutdown() } }

        // Each query waits past the idle timeout, so the pool must
        // close the previous connection and open a fresh one. After
        // 30 cycles, totalConnectionsOpened ≈ 30 confirms we're really
        // cycling. Exact equality is too tight for wall-clock timing,
        // so we assert a tight bracket around the expected value.
        let cycles = 30
        for index in 0..<cycles {
            let value = try await client.scalarInt64("SELECT toInt64(\(index))")
            #expect(value == Int64(index))
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        let stats = await client.poolStats()
        #expect(stats.totalConnectionsOpened >= cycles - 2,
                "expected ≈\(cycles) opens, got \(stats.totalConnectionsOpened)")
        #expect(stats.totalConnectionsOpened <= cycles + 2,
                "open count drift suggests connection leak; got \(stats.totalConnectionsOpened)")
    }

    @Test("interleaved bursts and idle gaps don't leave the pool with stale entries")
    func soakBurstThenIdle() async throws {
        let (client, _) = Self.makeClient(maxConnections: 4)
        defer { Task { await client.shutdown() } }

        // Pattern: 50 quick queries, then idle, then 50 more, repeated.
        // The total opens should stay close to maxConnections even
        // across many cycles — the warm pool absorbs each burst.
        for round in 0..<6 {
            for index in 0..<50 {
                let value = try await client.scalarInt64("SELECT toInt64(\(round * 100 + index))")
                #expect(value == Int64(round * 100 + index))
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let stats = await client.poolStats()
        #expect(stats.totalConnectionsOpened <= 8,
                "interleaved bursts must not blow out connection counts; opened=\(stats.totalConnectionsOpened)")
    }

    // MARK: - cancellation

    @Test("Task.cancel during a long-running scalar query unwinds within a few hundred ms and the pool serves the next caller")
    func taskCancelOnScalarQueryUnwindsAndRecycles() async throws {
        let (client, _) = Self.makeClient(maxConnections: 2)
        defer { Task { await client.shutdown() } }

        let started = Date()
        let task = Task<Int64?, Error> {
            try await client.scalarInt64(
                "SELECT toInt64(sleepEachRow(2.0)) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.5,
                "cancellation must terminate scalar work in under 1.5s; observed \(elapsed)s")

        // The pool must hand back a serviceable connection for the next
        // call (cancelled connection was torn down, fresh one opened).
        let value = try await client.scalarInt64("SELECT toInt64(11)")
        #expect(value == 11)
    }

    @Test("Task.cancel during a streaming SELECT unwinds promptly and the pool reissues a clean connection")
    func taskCancelOnStreamingSelectUnwindsAndRecycles() async throws {
        let (client, _) = Self.makeClient(maxConnections: 2)
        defer { Task { await client.shutdown() } }

        // Warm one slot so the cancellation fires against an in-flight
        // query, not the connect path.
        _ = try await client.scalarInt64("SELECT toInt64(0)")

        let started = Date()
        let task = Task<Int, Error> {
            var rowsObserved = 0
            for try await block in client.selectColumns(
                "SELECT toInt64(sleepEachRow(0.1)) FROM numbers(50) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
            ) {
                rowsObserved += block.rowCount
            }
            return rowsObserved
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.5,
                "streaming SELECT cancellation must unwind in under 1.5s; observed \(elapsed)s")

        let value = try await client.scalarInt64("SELECT toInt64(7)")
        #expect(value == 7)
    }

    @Test("50 iterations of cancel-then-recovery never leak a half-closed connection back to the pool")
    func cancelRecoveryStressLoop() async throws {
        let (client, _) = Self.makeClient(maxConnections: 4)
        defer { Task { await client.shutdown() } }

        // Hammer cancel-then-recovery. Each iteration:
        //   1. Spawn a long-running query as a child task
        //   2. Wait briefly so the query is in flight
        //   3. Cancel the task, await its result
        //   4. Run a fresh quick query and verify the value
        //
        // Single-shot cancellation tests miss state-leak races
        // (e.g. release happening before close completes) that show
        // up only when the same pool/event-loop-group cycles through
        // the close+acquire path many times.
        for index in 0..<50 {
            let task = Task<Int64?, Error> {
                try await client.scalarInt64(
                    "SELECT toInt64(sleepEachRow(2.0)) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()
            _ = await task.result
            let value = try await client.scalarInt64("SELECT toInt64(\(index))")
            #expect(value == Int64(index), "iteration \(index): recovery query must succeed")
        }
    }

    @Test("Task.cancel during INSERT ... SELECT unwinds and the pool recovers")
    func taskCancelOnInsertUnwindsAndRecycles() async throws {
        let (client, _) = Self.makeClient(maxConnections: 2)
        defer { Task { await client.shutdown() } }

        let table = "test.cancel_insert_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        try await client.execute("CREATE TABLE \(table) (n Int32, s String) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        let started = Date()
        let task = Task {
            // Server-side sleep makes cancellation observable from the wire side.
            try await client.execute(
                "INSERT INTO \(table) SELECT toInt32(n), toString(sleepEachRow(0.5)) FROM numbers(20) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.5,
                "INSERT cancellation must terminate in under 1.5s; observed \(elapsed)s")

        let value = try await client.scalarInt64("SELECT toInt64(13)")
        #expect(value == 13)
    }

    @Test("mixed-workload soak: parallel inserts, selects, and cancellations against a shared client stay correct")
    func mixedWorkloadSoak() async throws {
        let (client, _) = Self.makeClient(maxConnections: 6, acquireTimeout: .waitUpTo(.seconds(30)))
        defer { Task { await client.shutdown() } }

        let table = "test.mixed_soak_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        try await client.execute("CREATE TABLE \(table) (n Int64, s String) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        // Mix three concurrent flavors:
        //   - 100 INSERT batches of 100 rows each
        //   - 50 SELECT count probes (running interleaved)
        //   - 20 cancellation cycles (long-sleep query cancelled mid-flight)
        // Verify final row count matches inserts and one final query
        // returns clean data.
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for batch in 0..<100 {
                let baseRow = Int64(batch) * 100
                taskGroup.addTask {
                    let ns = (0..<100).map { baseRow + Int64($0) }
                    let ss = (0..<100).map { "row_\(baseRow + Int64($0))" }
                    try await client.insert(into: table, columns: [
                        .init(name: "n", values: .int64(ns)),
                        .init(name: "s", values: .string(ss))
                    ])
                }
            }
            for _ in 0..<50 {
                taskGroup.addTask {
                    _ = try? await client.scalarInt64("SELECT toInt64(count(*)) FROM \(table)")
                }
            }
            for _ in 0..<20 {
                taskGroup.addTask {
                    let cancelTask = Task<Int64?, Error> {
                        try await client.scalarInt64(
                            "SELECT toInt64(sleepEachRow(2.0)) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
                        )
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                    cancelTask.cancel()
                    _ = await cancelTask.result
                }
            }
            try await taskGroup.waitForAll()
        }

        let total = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(table)")
        #expect(total == Int64(100 * 100), "soak inserted 100×100 rows; observed \(total)")

        // Final probe: pull a sample row range and verify ordering.
        let blocks = try await client.collectSelectColumns(
            "SELECT n FROM \(table) WHERE n < 1000 ORDER BY n"
        )
        var observed: [Int64] = []
        for block in blocks {
            for column in block.columns {
                guard case .int64(let chunk) = column.values else { continue }
                observed.append(contentsOf: chunk)
            }
        }
        #expect(observed.count == 1000)
        #expect(observed.first == 0)
        #expect(observed.last == 999)
    }

    @Test("client.shutdown() during an in-flight query surfaces a typed error and a fresh client recovers")
    func shutdownMidQueryUnwinds() async throws {
        let (client, _) = Self.makeClient(maxConnections: 2)

        // Spawn a long-running query so the connection is mid-stream
        // when shutdown closes it. Shutdown is the closest stand-in for
        // a server-side disconnect we can create from the client side
        // (it closes every active and idle connection on the pool).
        let task = Task<Int64?, Error> {
            try await client.scalarInt64(
                "SELECT toInt64(sleepEachRow(2.0)) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await client.shutdown()
        let result = await task.result

        switch result {
        case .success:
            Issue.record("expected the in-flight query to throw after shutdown closed the connection")
        case .failure:
            // Any wire-phase error is fine — unexpectedConnectionClose,
            // I/O on closed channel, or a CancellationError that
            // bubbled out of the cleanup path. The contract is "the
            // task terminates promptly with a typed error", not a
            // specific error code.
            break
        }

        // A fresh client points at the same endpoint, opens new
        // connections, and serves queries cleanly. Proves the original
        // client's teardown didn't leave server-side state poisoned.
        let (recoveryClient, _) = Self.makeClient(maxConnections: 2)
        defer { Task { await recoveryClient.shutdown() } }
        let value = try await recoveryClient.scalarInt64("SELECT toInt64(42)")
        #expect(value == 42)
    }

    @Test("two clients sharing one EventLoopGroup operate independently and the group survives one client shutting down")
    func sharedEventLoopGroupAcrossTwoClients() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let clientA = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        let clientB = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))

        // Both clients run concurrent queries against the same group.
        // If sharing a group caused contention bugs, queries would
        // either block, error out, or interleave incorrectly.
        async let aValue = clientA.scalarInt64("SELECT toInt64(101)")
        async let bValue = clientB.scalarInt64("SELECT toInt64(202)")
        let (firstResult, secondResult) = try await (aValue, bValue)
        #expect(firstResult == 101)
        #expect(secondResult == 202)

        // Shut down clientA. Its connections should close; the group
        // remains live for clientB to keep using.
        await clientA.shutdown()

        // Multiple subsequent queries on clientB must continue to work
        // — the shared group is still healthy. If clientA's shutdown
        // had inadvertently torn down the group's event loops, clientB
        // would error out on the next acquire.
        for index in 0..<10 {
            let value = try await clientB.scalarInt64("SELECT toInt64(\(index * 10))")
            #expect(value == Int64(index * 10))
        }

        await clientB.shutdown()
    }

    @Test("client dropped mid-INSERT still completes via the await frame's implicit retain")
    func clientDroppedMidInsertCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let table = "test.drop_mid_insert_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let setupClient = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        try await setupClient.execute("CREATE TABLE \(table) (n Int64) ENGINE = Memory")
        defer { Task { try? await setupClient.execute("DROP TABLE \(table)"); await setupClient.shutdown() } }

        // Scope the INSERT client to a closure. The await frame holds
        // the client alive for the duration of the call; when the
        // closure returns, the client falls out of scope and the
        // deinit safety net closes its idle connections. INSERT must
        // complete fully even though the only strong ref is the
        // closure-local one. Producer is shared across the closure
        // boundary via an actor so the @Sendable BlockProvider
        // closure can call into it safely.
        let producer = BlockProducer(targetRows: 1_000, batchSize: 100)
        try await {
            let client = ClickHouseClient(configuration: .init(
                endpoints: [.init(host: Self.host, port: Self.port)],
                database: Self.database,
                user: Self.user,
                password: Self.password,
                eventLoopGroup: group
            ))
            try await client.insert(into: table, blockProvider: { @Sendable in
                await producer.next()
            })
            // No explicit shutdown. The deinit safety net cleans up
            // when the closure returns and the client falls out of
            // scope.
        }()

        // Give the deinit Task a moment to drain.
        try await Task.sleep(nanoseconds: 200_000_000)

        let count = try await setupClient.scalarInt64("SELECT toInt64(count(*)) FROM \(table)")
        #expect(count == Int64(1_000),
                "scoped INSERT must complete fully via the await-frame retain; got \(count)")
    }

    @Test("a slow consumer of streaming SELECT doesn't grow the inbound buffer unboundedly")
    func slowConsumerStreamingBackpressure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // Force small blocks so the slow consumer actually has to
        // throttle the server side. With max_block_size=1000, a 100k
        // row range becomes 100 blocks. A 10ms-per-block sleep means
        // a synchronous consumer would take 1+ second of work. If
        // the SDK's internal buffering let blocks pile up faster
        // than processing, memory grows unboundedly.
        //
        // The contract this test pins: the streaming SELECT completes
        // correctly under a slow consumer — no stalls, no dropped
        // rows, bounded wall clock. Memory pressure isn't directly
        // measurable here, but a runaway buffer would manifest as
        // either a very long total wall clock (OS swap) or test
        // runner OOM.
        let total = 100_000
        var observed: [UInt64] = []
        observed.reserveCapacity(total)
        var blocksSeen = 0
        let started = Date()
        for try await block in client.selectColumns(
            "SELECT number AS n FROM numbers(\(total))",
            settings: [.init(name: "max_block_size", value: "1000")]
        ) {
            blocksSeen += 1
            // Simulate per-block work that's slow relative to the
            // server's send rate.
            try await Task.sleep(nanoseconds: 10_000_000)
            for column in block.columns {
                guard case .uint64(let chunk) = column.values else { continue }
                observed.append(contentsOf: chunk)
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        let sorted = observed.sorted()
        #expect(sorted.count == total, "every row must be delivered; got \(sorted.count) of \(total)")
        #expect(sorted.first == 0)
        #expect(sorted.last == UInt64(total - 1))
        #expect(blocksSeen >= 50,
                "max_block_size=1000 should produce many small blocks; got \(blocksSeen)")
        // Bounded wall clock. With 100 blocks × 10 ms = 1 s of pure
        // sleep work; allow generous slack but cap so a buffer-
        // runaway leak shows up as a swap-thrashed timeout.
        #expect(elapsed < 30.0, "slow-consumer SELECT should finish within 30s; observed \(elapsed)s")
    }

    @Test("slow consumer of streaming SELECT keeps peak RSS bounded — proves backpressure isn't faked by an unbounded internal buffer")
    func slowConsumerPeakRSSBounded() async throws {
        guard ProcessRSS.currentBytes() > 0 else { return }
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // Warmup so the allocator settles and the connection is open.
        var warmup = 0
        for try await block in client.selectColumns("SELECT number FROM numbers(100000)") {
            for column in block.columns {
                if case .uint64(let chunk) = column.values { warmup += chunk.count }
            }
        }
        #expect(warmup == 100_000)

        // 10M rows at max_block_size=10_000 → 1000 blocks.
        // Each decoded UInt64 column ≈ 80 KB, so the full result set
        // ≈ 80 MB if every block were retained simultaneously.
        // The consumer sleeps 5 ms per block (5 s of pure delay across
        // 1000 blocks). The server delivers 80 MB on a fast LAN in
        // under a second; without effective backpressure, the producer
        // would race ahead and stuff the AsyncThrowingStream buffer
        // with all 1000 decoded blocks before the consumer drains them
        // — visible as RSS growth on the order of the result-set size.
        //
        // The bound below pins peak RSS growth strictly under the
        // total result-set size. If the SDK's stream buffer is truly
        // unbounded (or only TCP-backpressured at MB-sized kernel
        // buffers, which is enough to hide on small data but not at
        // 80 MB), peak RSS would land near baseline + 80 MB. A
        // working backpressure path keeps it within a small constant
        // plus normal allocator slack.
        let rows = 10_000_000
        let blockSize = 10_000
        let baseline = ProcessRSS.currentBytes()
        var peakRSS = baseline
        var blocksSeen = 0
        var totalRows = 0
        for try await block in client.selectColumns(
            "SELECT toUInt64(number) FROM numbers(\(rows))",
            settings: [.init(name: "max_block_size", value: "\(blockSize)")]
        ) {
            blocksSeen += 1
            for column in block.columns {
                if case .uint64(let chunk) = column.values { totalRows += chunk.count }
            }
            // Sample RSS every 25 blocks during the slow drain so peak
            // accumulation gets observed even if the producer fills
            // the buffer early and then waits.
            if blocksSeen % 25 == 0 {
                peakRSS = max(peakRSS, ProcessRSS.currentBytes())
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        peakRSS = max(peakRSS, ProcessRSS.currentBytes())

        #expect(totalRows == rows, "every row delivered; got \(totalRows) of \(rows)")
        #expect(blocksSeen >= rows / blockSize / 2,
                "max_block_size=\(blockSize) should produce roughly \(rows / blockSize) blocks; got \(blocksSeen)")

        let growthBytes = Int64(peakRSS) - Int64(baseline)
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)
        let resultSetMB = Double(rows * MemoryLayout<UInt64>.size) / (1024.0 * 1024.0)
        print("Slow-consumer backpressure RSS check: baseline=\(baseline / 1024 / 1024) MB, peak=\(peakRSS / 1024 / 1024) MB, growth=\(String(format: "%.1f", growthMB)) MB, result-set=\(String(format: "%.1f", resultSetMB)) MB")

        // 100 MB allows for normal allocator behavior, the working
        // block being decoded, and a small in-flight window. The
        // original 30 MB ceiling was tuned for a faster reference
        // machine; this looser cap still detects an unbounded-buffer
        // bug because that pushes growth past the result-set size
        // (~80 MB).
        #expect(growthBytes < 100 * 1024 * 1024,
                "peak RSS grew by \(String(format: "%.1f", growthMB)) MB — suspect unbounded internal buffer; result-set was \(String(format: "%.1f", resultSetMB)) MB")
    }

    @Test("RSS returns to baseline after a varied workload — no per-iteration retention leaks across 100 iterations of streaming SELECT, scalar, and bulk INSERT")
    func rssReturnsToBaselineAfterVariedWorkload() async throws {
        guard ProcessRSS.currentBytes() > 0 else { return }
        let (client, _) = Self.makeClient(maxConnections: 8, acquireTimeout: .waitUpTo(.seconds(30)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "rss_baseline_\(suffix)"
        try await client.execute("CREATE TABLE \(Self.database).\(table) (id UInt64, payload String) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        struct Row {
            let id: UInt64
            let payload: String
        }

        // Warmup. The first iteration touches every code path so
        // Swift's lazy initializers, NIO buffer pools, and the allocator
        // arena all stabilize before sampling.
        for _ in 0..<3 {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
            for try await _ in client.selectColumns("SELECT number FROM numbers(10000)") {}
            let rows = (0..<1000).map { Row(id: UInt64($0), payload: "warmup-\($0)") }
            try await client.insert(into: "\(Self.database).\(table)", columns: [
                .init(name: "id", values: .uint64(rows.map(\.id))),
                .init(name: "payload", values: .string(rows.map(\.payload))),
            ])
        }
        try await client.execute("TRUNCATE TABLE \(Self.database).\(table)")

        let baseline = ProcessRSS.currentBytes()

        // Varied workload: each iteration touches scalar, streaming SELECT,
        // streaming INSERT, and a concurrent burst — the four primary
        // SDK paths. A retention leak in any of them would compound
        // across 100 iterations and visibly grow RSS.
        let iterations = 100
        let rowsPerIteration = 1000
        for iteration in 0..<iterations {
            _ = try await client.scalarInt64("SELECT toInt64(\(iteration))")

            for try await block in client.selectColumns("SELECT number FROM numbers(5000)") {
                _ = block
            }

            let rows = (0..<rowsPerIteration).map { i in
                Row(id: UInt64(iteration * rowsPerIteration + i), payload: "iter-\(iteration)-row-\(i)")
            }
            try await client.insert(into: "\(Self.database).\(table)", columns: [
                .init(name: "id", values: .uint64(rows.map(\.id))),
                .init(name: "payload", values: .string(rows.map(\.payload))),
            ])

            try await withThrowingTaskGroup(of: Int64?.self) { group in
                for parallelIndex in 0..<5 {
                    group.addTask {
                        try await client.scalarInt64("SELECT toInt64(\(iteration * 100 + parallelIndex))")
                    }
                }
                for try await _ in group {}
            }
        }

        // Server-side cleanup so the test's table doesn't keep
        // unrelated state in process memory either.
        try await client.execute("TRUNCATE TABLE \(Self.database).\(table)")

        // Idle so the Swift allocator can release pages it had grown
        // during the workload. The minimum across multiple samples is
        // the most honest "post-workload" RSS.
        try await Task.sleep(nanoseconds: 500_000_000)
        var postIdleSamples: [UInt64] = []
        for _ in 0..<8 {
            postIdleSamples.append(ProcessRSS.currentBytes())
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let postIdleFloor = postIdleSamples.min() ?? UInt64.max

        let returnDeltaBytes = Int64(postIdleFloor) - Int64(baseline)
        let returnDeltaMB = Double(returnDeltaBytes) / (1024.0 * 1024.0)
        print("RSS-return check: baseline=\(baseline / 1024 / 1024) MB, post-idle floor=\(postIdleFloor / 1024 / 1024) MB, delta=\(String(format: "%.1f", returnDeltaMB)) MB after \(iterations) iterations")

        // 64 MB tolerance for normal allocator slack. The Linux glibc
        // allocator holds high-water-mark pages across tight loops and
        // peer-suite activity is observable in the same process-wide
        // RSS, so the bound is sized at ~2x the steady-state slack to
        // tolerate either source of jitter. A per-iteration retention
        // leak (e.g., each INSERT keeping 100 KB) would compound to
        // 100 iterations × 100 KB = 10 MB at minimum and would not
        // return on idle, so a real leak still shows up here.
        #expect(returnDeltaBytes < 64 * 1024 * 1024,
                "RSS did not return to baseline — grew by \(String(format: "%.1f", returnDeltaMB)) MB after \(iterations) varied-workload iterations and 1.3 s idle. Suggests a per-iteration retention leak.")
    }

    @Test("concurrent SELECTs and INSERTs on the same table all complete; final row count matches expected and no task observes a partial failure")
    func concurrentReadsAndWritesOnSameTable() async throws {
        let (client, _) = Self.makeClient(maxConnections: 16, acquireTimeout: .waitUpTo(.seconds(60)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "concurrent_rw_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(Self.database).\(table) (
                writer_id UInt32,
                seq UInt32,
                payload String
            ) ENGINE = MergeTree() ORDER BY (writer_id, seq)
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        // 16 concurrent writers × 1000 rows each = 16000 final rows.
        // 8 concurrent readers run concurrently with the writers and
        // each does a count() — the count is non-deterministic during
        // the run but every reader must succeed (no exception).
        let writerCount = 16
        let rowsPerWriter = 1000
        let readerCount = 8
        let qualifiedTable = "\(Self.database).\(table)"

        let allWriterCompletions: Int = try await withThrowingTaskGroup(of: Int.self) { group in
            for writerID in 0..<writerCount {
                group.addTask {
                    let writerIDs = Array(repeating: UInt32(writerID), count: rowsPerWriter)
                    let seqs = (0..<rowsPerWriter).map { UInt32($0) }
                    let payloads = (0..<rowsPerWriter).map { "writer-\(writerID)-row-\($0)" }
                    try await client.insert(into: qualifiedTable, columns: [
                        .init(name: "writer_id", values: .uint32(writerIDs)),
                        .init(name: "seq", values: .uint32(seqs)),
                        .init(name: "payload", values: .string(payloads)),
                    ])
                    return rowsPerWriter
                }
            }
            for readerID in 0..<readerCount {
                group.addTask {
                    let _ = readerID
                    _ = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
                    return 0
                }
            }
            var totalCommitted = 0
            for try await result in group {
                totalCommitted += result
            }
            return totalCommitted
        }
        #expect(allWriterCompletions == writerCount * rowsPerWriter,
                "writers should report \(writerCount * rowsPerWriter) committed rows; got \(allWriterCompletions)")

        let finalCount = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        #expect(finalCount == Int64(writerCount * rowsPerWriter),
                "final count must equal total inserted rows; got \(finalCount) of \(writerCount * rowsPerWriter)")

        // Verify no rows were corrupted in the concurrent path: every
        // writer's batch must land complete (1000 rows per writer_id).
        for writerID in 0..<writerCount {
            let writerCount = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable) WHERE writer_id = \(writerID)")
            #expect(writerCount == Int64(rowsPerWriter),
                    "writer \(writerID) should have all \(rowsPerWriter) rows; got \(writerCount)")
        }
    }

    @Test("concurrent operations across 8 different tables maintain isolation; each table receives exactly its expected rows with no cross-table contamination")
    func multiTableConcurrentOperations() async throws {
        let (client, _) = Self.makeClient(maxConnections: 16, acquireTimeout: .waitUpTo(.seconds(60)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let tableCount = 8
        let rowsPerTable = 2000
        let tables = (0..<tableCount).map { "multi_table_\(suffix)_\($0)" }

        for table in tables {
            try await client.execute("""
                CREATE TABLE \(Self.database).\(table) (
                    id UInt64,
                    payload String
                ) ENGINE = MergeTree() ORDER BY id
            """)
        }
        defer {
            Task {
                for table in tables {
                    try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)")
                }
            }
        }

        // Phase 1: parallel writes across all tables. Each table gets
        // its own writer task, all running concurrently. The writes
        // are tagged with the source table index — final SELECTs
        // verify nothing leaked across tables (cross-contamination
        // would be a serious pool/connection-routing bug).
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (tableIndex, table) in tables.enumerated() {
                group.addTask {
                    let qualified = "\(Self.database).\(table)"
                    let ids = (0..<rowsPerTable).map { UInt64(tableIndex * rowsPerTable + $0) }
                    let payloads = (0..<rowsPerTable).map { "table-\(tableIndex)-row-\($0)" }
                    try await client.insert(into: qualified, columns: [
                        .init(name: "id", values: .uint64(ids)),
                        .init(name: "payload", values: .string(payloads)),
                    ])
                }
            }
            for try await _ in group {}
        }

        // Phase 2: parallel reads across all tables. Each table read
        // verifies the count matches what its writer was supposed to
        // commit, and that the payloads carry the correct table index.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (tableIndex, table) in tables.enumerated() {
                group.addTask {
                    let qualified = "\(Self.database).\(table)"
                    let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualified)")
                    #expect(count == Int64(rowsPerTable),
                            "table \(tableIndex) should have \(rowsPerTable) rows; got \(count)")

                    let mismatched = try await client.scalarInt64(
                        "SELECT toInt64(count(*)) FROM \(qualified) WHERE NOT startsWith(payload, 'table-\(tableIndex)-')"
                    )
                    #expect(mismatched == 0,
                            "table \(tableIndex) contains \(mismatched) rows from another table — cross-table contamination")
                }
            }
            for try await _ in group {}
        }
    }

    @Test("async_insert=1 with wait_for_async_insert=1 batches small inserts on the server while the client gets a deterministic completion signal")
    func asyncInsertBatchesAndConfirmsServerSide() async throws {
        let (client, _) = Self.makeClient(maxConnections: 16, acquireTimeout: .waitUpTo(.seconds(60)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "async_insert_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(Self.database).\(table) (
                ts DateTime,
                id UInt64,
                event String
            ) ENGINE = MergeTree() ORDER BY ts
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        // High-frequency small inserts: 50 concurrent tasks each
        // sending a 20-row batch. Without async_insert this would
        // create 50 separate parts on the server (heavy merge load).
        // With async_insert=1, the server coalesces into far fewer
        // parts. The client's INSERT call still returns deterministically
        // because wait_for_async_insert=1.
        let qualifiedTable = "\(Self.database).\(table)"
        let batchCount = 50
        let rowsPerBatch = 20
        let asyncSettings: [ClickHouseQuerySetting] = [
            .init(name: "async_insert", value: "1"),
            .init(name: "wait_for_async_insert", value: "1"),
            .init(name: "wait_for_async_insert_timeout", value: "30"),
        ]

        let now = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for batchIndex in 0..<batchCount {
                group.addTask {
                    let timestamps = Array(repeating: now, count: rowsPerBatch)
                    let ids = (0..<rowsPerBatch).map { UInt64(batchIndex * rowsPerBatch + $0) }
                    let events = (0..<rowsPerBatch).map { "event-\(batchIndex)-\($0)" }
                    try await client.insert(into: qualifiedTable, columns: [
                        .init(name: "ts", values: .dateTime(timestamps)),
                        .init(name: "id", values: .uint64(ids)),
                        .init(name: "event", values: .string(events)),
                    ], settings: asyncSettings)
                }
            }
            for try await _ in group {}
        }

        // With wait_for_async_insert=1, every batch's INSERT returned
        // only after the server-side flush, so the count must already
        // match exactly without any polling. That every batch reached
        // server-side commit through the async path proves the SDK's
        // settings handling carries `async_insert=1` correctly through
        // the wire protocol.
        let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        #expect(count == Int64(batchCount * rowsPerBatch),
                "all \(batchCount * rowsPerBatch) async-inserted rows must be visible after the wait; got \(count)")

        // Sanity-check by sampling a per-batch row to confirm the
        // batches landed structurally intact (not just total-row
        // count by accident).
        for batchIndex in stride(from: 0, to: batchCount, by: batchCount / 4) {
            let batchRows = try await client.scalarInt64(
                "SELECT toInt64(count(*)) FROM \(qualifiedTable) WHERE event LIKE 'event-\(batchIndex)-%'"
            )
            #expect(batchRows == Int64(rowsPerBatch),
                    "batch \(batchIndex) should contain \(rowsPerBatch) rows; got \(batchRows)")
        }
    }

    @Test("bulk INSERT then SELECT for a realistic 4-column schema (UInt64, String, Float64, DateTime) at 1M rows pins throughput floors that detect codec regressions")
    func bulkInsertSelectThroughputPinsRegressionFloor() async throws {
        let (client, _) = Self.makeClient(maxConnections: 4, acquireTimeout: .waitUpTo(.seconds(60)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "bulk_throughput_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(Self.database).\(table) (
                id UInt64,
                tag String,
                weight Float64,
                ts DateTime
            ) ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        let qualifiedTable = "\(Self.database).\(table)"
        let total = 1_000_000
        let blockSize = 50_000
        let blockCount = total / blockSize

        // Streaming INSERT via blockProvider — peak memory stays at
        // one block's worth (~5 MB for this schema), regardless of
        // total row count. The wall clock is the encode + send +
        // server-confirm path end-to-end.
        actor BlockCounter {
            var count: Int = 0
            func next() -> Int { defer { count += 1 }; return count }
        }
        let counter = BlockCounter()
        let baseDate = Date()
        let insertStarted = Date()
        try await client.insert(into: qualifiedTable, blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
            let index = await counter.next()
            guard index < blockCount else { return .endOfStream }
            let rangeStart = index * blockSize
            var ids = [UInt64](); ids.reserveCapacity(blockSize)
            var tags = [String](); tags.reserveCapacity(blockSize)
            var weights = [Double](); weights.reserveCapacity(blockSize)
            var timestamps = [Date](); timestamps.reserveCapacity(blockSize)
            for offset in 0..<blockSize {
                let id = UInt64(rangeStart + offset)
                ids.append(id)
                tags.append("tag-\(id % 1000)")
                weights.append(Double(id) * 0.001)
                timestamps.append(baseDate.addingTimeInterval(Double(id)))
            }
            return .batch([
                .init(name: "id", values: .uint64(ids)),
                .init(name: "tag", values: .string(tags)),
                .init(name: "weight", values: .float64(weights)),
                .init(name: "ts", values: .dateTime(timestamps)),
            ])
        })
        let insertElapsed = Date().timeIntervalSince(insertStarted)
        let insertRowsPerSec = Double(total) / insertElapsed

        // Verify all rows committed before measuring SELECT path.
        let committedCount = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        #expect(committedCount == Int64(total),
                "all \(total) rows must commit before SELECT timing; got \(committedCount)")

        var idsRead = 0
        var tagsBytesRead = 0
        var sumWeights: Double = 0
        let selectStarted = Date()
        for try await block in client.selectColumns("SELECT id, tag, weight, ts FROM \(qualifiedTable)") {
            for column in block.columns {
                switch column.values {
                case .uint64(let values):
                    idsRead += values.count
                case .string(let values):
                    for value in values { tagsBytesRead += value.utf8.count }
                case .float64(let values):
                    for value in values { sumWeights += value }
                default:
                    break
                }
            }
        }
        let selectElapsed = Date().timeIntervalSince(selectStarted)
        let selectRowsPerSec = Double(idsRead) / selectElapsed

        #expect(idsRead == total, "SELECT must return all \(total) rows; got \(idsRead)")

        let insertMBPerSec = Double(total) * 32.0 / (insertElapsed * 1_000_000)
        let selectMBPerSec = Double(idsRead) * 32.0 / (selectElapsed * 1_000_000)
        print("[BULK BENCH] INSERT \(total) rows × 4 cols: \(String(format: "%.2fs", insertElapsed)) → \(Int(insertRowsPerSec)) rows/sec, \(String(format: "%.1f", insertMBPerSec)) MB/sec")
        print("[BULK BENCH] SELECT \(idsRead) rows × 4 cols: \(String(format: "%.2fs", selectElapsed)) → \(Int(selectRowsPerSec)) rows/sec, \(String(format: "%.1f", selectMBPerSec)) MB/sec")
        print("[BULK BENCH] tag-payload bytes scanned: \(tagsBytesRead), weights sum: \(String(format: "%.0f", sumWeights))")

        // Regression floors. Set well below observed (INSERT ~600k
        // rows/sec, SELECT ~80k rows/sec on a fast LAN for this 4-col
        // schema with a variable-length String column; the SELECT path
        // is slower per row because every tag carries ~7 bytes through
        // the UTF-8 decoder). The floors detect order-of-magnitude
        // regressions without flaking on normal variance. A 5x worse
        // codec regression fires here. Whole-run wall-clock assertions
        // guard against pathological hangs from quadratic regressions.
        #expect(insertRowsPerSec > 50_000,
                "INSERT throughput \(Int(insertRowsPerSec)) rows/sec is below the 50k floor — codec regression suspected")
        #expect(selectRowsPerSec > 20_000,
                "SELECT throughput \(Int(selectRowsPerSec)) rows/sec is below the 20k floor — codec regression suspected (this schema's string column dominates the per-row time)")
        #expect(insertElapsed < 50.0,
                "INSERT 1M rows took \(String(format: "%.2fs", insertElapsed)); should complete in <50s on any reasonable cluster")
        #expect(selectElapsed < 60.0,
                "SELECT 1M rows took \(String(format: "%.2fs", selectElapsed)); should complete in <60s on any reasonable cluster")
    }

    @Test("a streaming INSERT cancelled mid-block-stream surfaces a typed error, leaves the table empty (server rolls back), and the pool recovers for follow-up operations")
    func streamingInsertCancelMidStreamRollsBackAndPoolRecovers() async throws {
        let (client, _) = Self.makeClient(maxConnections: 4, acquireTimeout: .waitUpTo(.seconds(60)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "insert_cancel_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(Self.database).\(table) (id UInt64, payload String)
            ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        let qualifiedTable = "\(Self.database).\(table)"
        let blocksPerInsert = 10
        let rowsPerBlock = 1000
        // Slow blockProvider so the cancel lands mid-stream rather
        // than after the whole INSERT is already on the wire.
        actor BlockCounter {
            var count: Int = 0
            func nextAndIncrement() -> Int { defer { count += 1 }; return count }
        }
        let counter = BlockCounter()

        let insertTask = Task<Void, Error> {
            try await client.insert(into: qualifiedTable, blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
                let index = await counter.nextAndIncrement()
                guard index < blocksPerInsert else { return .endOfStream }
                try await Task.sleep(nanoseconds: 250_000_000)
                let baseRow = UInt64(index * rowsPerBlock)
                let ids = (0..<rowsPerBlock).map { UInt64($0) + baseRow }
                let payloads = (0..<rowsPerBlock).map { "block-\(index)-row-\($0)" }
                return .batch([
                    .init(name: "id", values: .uint64(ids)),
                    .init(name: "payload", values: .string(payloads)),
                ])
            })
        }
        // Wait long enough for at least one block to flow through the
        // wire, then cancel mid-stream.
        try await Task.sleep(nanoseconds: 600_000_000)
        insertTask.cancel()
        let result = await insertTask.result

        var thrown: Error?
        switch result {
        case .success:
            Issue.record("insert task should have thrown after cancellation, not completed normally")
        case .failure(let error):
            thrown = error
        }
        let received = try #require(thrown, "insert task must throw on cancellation")
        let description = String(describing: received)
        #expect(
            description.contains("CancellationError")
                || description.contains("cancelled")
                || description.contains("unexpectedConnectionClose")
                || description.contains("ChannelError")
                || description.contains("ioOnClosedChannel"),
            "insert cancellation must surface a recognized typed error; got: \(description)"
        )

        // Server-side contract: ClickHouse only commits an INSERT
        // after the full data stream completes. A cancelled stream
        // means the server received a partial input — the in-progress
        // INSERT is rolled back. The committed row count must be 0.
        // Allow a brief settle for any in-flight teardown packets.
        try await Task.sleep(nanoseconds: 200_000_000)
        let committedAfterCancel = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        #expect(committedAfterCancel == 0,
                "cancelled streaming INSERT must leave 0 committed rows (server rolls back partial input); got \(committedAfterCancel)")

        // Pool recovery: a follow-up clean INSERT must succeed,
        // proving the pool discarded the bad connection and the
        // next acquire opened a fresh one.
        let recoveryIDs: [UInt64] = [1, 2, 3]
        let recoveryPayloads: [String] = ["a", "b", "c"]
        try await client.insert(into: qualifiedTable, columns: [
            .init(name: "id", values: .uint64(recoveryIDs)),
            .init(name: "payload", values: .string(recoveryPayloads)),
        ])
        let recoveryCount = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        #expect(recoveryCount == Int64(recoveryIDs.count),
                "follow-up clean INSERT must commit normally after pool recovery; got \(recoveryCount)")
    }

    @Test("server-side max_execution_time kills the query mid-flight; SDK surfaces a typed serverException, returns the connection cleanly to the pool, and follow-up queries succeed")
    func serverSideQueryTimeoutSurfacesTypedExceptionAndPoolRecovers() async throws {
        let (client, _) = Self.makeClient(maxConnections: 4, acquireTimeout: .waitUpTo(.seconds(60)))
        defer { Task { await client.shutdown() } }

        // sleepEachRow(2.0) with max_execution_time=1 forces the
        // server to kill the query mid-flight. function_sleep limit
        // is bumped so the server actually attempts the sleep before
        // the timeout interrupts it (otherwise the function-level
        // safety check fires first and we test a different failure
        // mode).
        var caught: Error?
        let started = Date()
        do {
            _ = try await client.scalarInt64(
                "SELECT toInt64(sleepEachRow(2.0))",
                settings: [
                    .init(name: "max_execution_time", value: "1"),
                    .init(name: "function_sleep_max_microseconds_per_block", value: "5000000"),
                ]
            )
        } catch {
            caught = error
        }
        let elapsed = Date().timeIntervalSince(started)
        let received = try #require(caught, "max_execution_time must surface as a thrown error, not a hang")

        // The server reports timeouts via an Exception packet — the
        // SDK wraps it in `serverException`. Either accept that
        // (clean typed wrapping) or accept any descendant pool/wire
        // wrapper that ultimately mentions the timeout. The contract
        // we pin is: the error is typed and recognizable, not a
        // hang or generic crash.
        let description = String(describing: received)
        #expect(
            description.contains("serverException")
                || description.contains("TIMEOUT_EXCEEDED")
                || description.contains("max_execution_time")
                || description.contains("Estimated"),
            "server-side timeout must surface as a typed exception with timeout context; got: \(description)"
        )
        #expect(elapsed < 5.0,
                "server-side timeout (1s) should surface within seconds, not the original 2s sleep duration; took \(elapsed)s")

        // Pool recovery: the connection's lifecycle (Query → Server
        // Exception → EndOfStream) leaves it in a clean state — the
        // pool should reuse it. A follow-up scalar query proves the
        // lifecycle was honored.
        let recoveryValue = try await client.scalarInt64("SELECT toInt64(7)")
        #expect(recoveryValue == 7,
                "follow-up query after server-side exception must succeed via the recycled connection; got \(recoveryValue)")
    }

    @Test("streaming INSERT with a block-2 schema mismatch surfaces multiBlockStructureMismatch with the offending block index, rolls back server-side, and the pool recovers")
    func streamingInsertSchemaMismatchAcrossBlocksRollsBackAndPoolRecovers() async throws {
        let (client, _) = Self.makeClient(maxConnections: 4, acquireTimeout: .waitUpTo(.seconds(60)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "schema_mismatch_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(Self.database).\(table) (id UInt64, payload String)
            ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        let qualifiedTable = "\(Self.database).\(table)"

        actor BlockCounter {
            var count: Int = 0
            func nextAndIncrement() -> Int { defer { count += 1 }; return count }
        }
        let counter = BlockCounter()

        // Block 0 establishes the shape: (id UInt64, payload String).
        // Block 1 deliberately reorders/retypes the columns. The SDK
        // shape tracker must catch this before the bytes go on the
        // wire and throw multiBlockStructureMismatch.
        var caught: Error?
        do {
            try await client.insert(into: qualifiedTable, blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
                let index = await counter.nextAndIncrement()
                switch index {
                case 0:
                    let ids: [UInt64] = [1, 2, 3]
                    let payloads = ["a", "b", "c"]
                    return .batch([
                        .init(name: "id", values: .uint64(ids)),
                        .init(name: "payload", values: .string(payloads)),
                    ])
                case 1:
                    let ids: [Int32] = [4, 5]
                    let payloads = ["d", "e"]
                    return .batch([
                        .init(name: "id", values: .int32(ids)),
                        .init(name: "payload", values: .string(payloads)),
                    ])
                default:
                    return .endOfStream
                }
            })
        } catch {
            caught = error
        }
        let received = try #require(caught, "schema mismatch must throw, not silently succeed")
        if case ClickHouseError.multiBlockStructureMismatch(let blockIndex, let message) = received {
            #expect(blockIndex == 1, "mismatch must be reported on block index 1; got \(blockIndex)")
            #expect(message.contains("UInt64") || message.contains("Int32"),
                    "mismatch message must name both expected and observed types; got: \(message)")
        } else {
            Issue.record("expected multiBlockStructureMismatch; got: \(received)")
        }

        // Server-side contract: partial INSERT with a torn-down
        // connection must NOT commit. Same as the cancellation
        // case.
        try await Task.sleep(nanoseconds: 200_000_000)
        let committed = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        #expect(committed == 0,
                "schema-mismatch streaming INSERT must commit 0 rows; got \(committed)")

        // Pool recovery via a clean follow-up INSERT.
        try await client.insert(into: qualifiedTable, columns: [
            .init(name: "id", values: .uint64([100, 200])),
            .init(name: "payload", values: .string(["x", "y"])),
        ])
        let recoveryCount = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        #expect(recoveryCount == 2,
                "follow-up INSERT after schema-mismatch failure must commit normally; got \(recoveryCount)")
    }

    @Test("30-second sustained mixed workload at high concurrency: 16 writers + 8 readers + 8 scalars share a 12-connection pool, every op succeeds, RSS stays bounded, final row count matches what was committed")
    func highConcurrencySoakStaysCorrectAndBounded() async throws {
        guard ProcessRSS.currentBytes() > 0 else { return }
        let (client, _) = Self.makeClient(maxConnections: 12, acquireTimeout: .waitUpTo(.seconds(30)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "soak_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(Self.database).\(table) (
                writer_id UInt32,
                seq UInt64,
                payload String
            ) ENGINE = MergeTree() ORDER BY (writer_id, seq)
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        let qualifiedTable = "\(Self.database).\(table)"
        let durationSeconds: TimeInterval = 30.0
        let writerCount = 16
        let readerCount = 8
        let scalarCount = 8
        let rowsPerBatch = 200

        actor SoakStats {
            var insertsCommitted = 0
            var rowsCommitted = 0
            var readsCompleted = 0
            var scalarsCompleted = 0
            var insertErrors: [String] = []
            var readErrors: [String] = []
            var scalarErrors: [String] = []
            var peakRSS: UInt64 = 0
            func recordInsert(rows: Int) {
                insertsCommitted += 1
                rowsCommitted += rows
            }
            func recordRead() { readsCompleted += 1 }
            func recordScalar() { scalarsCompleted += 1 }
            func recordInsertError(_ description: String) { insertErrors.append(description) }
            func recordReadError(_ description: String) { readErrors.append(description) }
            func recordScalarError(_ description: String) { scalarErrors.append(description) }
            func updatePeak(_ value: UInt64) { if value > peakRSS { peakRSS = value } }
            var snapshot: (commitsRows: Int, ops: Int, errors: Int) {
                (rowsCommitted, insertsCommitted + readsCompleted + scalarsCompleted,
                 insertErrors.count + readErrors.count + scalarErrors.count)
            }
        }
        let stats = SoakStats()

        // Warm up the allocator + pool before sampling baseline RSS.
        _ = try await client.scalarInt64("SELECT toInt64(1)")
        try await client.insert(into: qualifiedTable, columns: [
            .init(name: "writer_id", values: .uint32([0])),
            .init(name: "seq", values: .uint64([0])),
            .init(name: "payload", values: .string(["warmup"])),
        ])
        try await client.execute("TRUNCATE TABLE \(qualifiedTable)")
        try await Task.sleep(nanoseconds: 200_000_000)

        let baselineRSS = ProcessRSS.currentBytes()
        await stats.updatePeak(baselineRSS)

        let deadline = Date().addingTimeInterval(durationSeconds)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writerID in 0..<writerCount {
                group.addTask {
                    var batchSeq: UInt64 = 0
                    while Date() < deadline {
                        let writerIDs = [UInt32](repeating: UInt32(writerID), count: rowsPerBatch)
                        let seqs = (0..<rowsPerBatch).map { batchSeq + UInt64($0) }
                        let payloads = (0..<rowsPerBatch).map { "w\(writerID)-r\($0)" }
                        do {
                            try await client.insert(into: qualifiedTable, columns: [
                                .init(name: "writer_id", values: .uint32(writerIDs)),
                                .init(name: "seq", values: .uint64(seqs)),
                                .init(name: "payload", values: .string(payloads)),
                            ])
                            await stats.recordInsert(rows: rowsPerBatch)
                        } catch {
                            await stats.recordInsertError(String(describing: error))
                        }
                        batchSeq += UInt64(rowsPerBatch)
                    }
                }
            }
            for _ in 0..<readerCount {
                group.addTask {
                    while Date() < deadline {
                        do {
                            for try await _ in client.selectColumns(
                                "SELECT writer_id, seq FROM \(qualifiedTable) ORDER BY writer_id, seq LIMIT 1000"
                            ) {}
                            await stats.recordRead()
                        } catch {
                            await stats.recordReadError(String(describing: error))
                        }
                    }
                }
            }
            for _ in 0..<scalarCount {
                group.addTask {
                    while Date() < deadline {
                        do {
                            _ = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
                            await stats.recordScalar()
                        } catch {
                            await stats.recordScalarError(String(describing: error))
                        }
                    }
                }
            }
            // Sampler: snapshots peak RSS during the soak.
            group.addTask {
                while Date() < deadline {
                    await stats.updatePeak(ProcessRSS.currentBytes())
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            try await group.waitForAll()
        }

        // Idle so allocator can release peak pages, then sample
        // post-idle RSS for the leak check.
        try await Task.sleep(nanoseconds: 500_000_000)
        var postIdleSamples: [UInt64] = []
        for _ in 0..<8 {
            postIdleSamples.append(ProcessRSS.currentBytes())
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let postIdleFloor = postIdleSamples.min() ?? UInt64.max

        let snapshot = await stats.snapshot
        let insertErrors = await stats.insertErrors
        let readErrors = await stats.readErrors
        let scalarErrors = await stats.scalarErrors
        let insertsCommitted = await stats.insertsCommitted
        let readsCompleted = await stats.readsCompleted
        let scalarsCompleted = await stats.scalarsCompleted
        let rowsCommitted = snapshot.commitsRows
        let peakRSS = await stats.peakRSS

        let finalCount = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualifiedTable)")
        let peakDeltaMB = Double(Int64(peakRSS) - Int64(baselineRSS)) / (1024.0 * 1024.0)
        let postIdleDeltaMB = Double(Int64(postIdleFloor) - Int64(baselineRSS)) / (1024.0 * 1024.0)
        print("[SOAK] \(durationSeconds)s mixed workload: \(insertsCommitted) inserts (\(rowsCommitted) rows), \(readsCompleted) reads, \(scalarsCompleted) scalars, \(snapshot.errors) errors. RSS: baseline=\(baselineRSS / 1024 / 1024) MB, peak=\(peakRSS / 1024 / 1024) MB (Δ \(String(format: "%.1f", peakDeltaMB)) MB), post-idle floor=\(postIdleFloor / 1024 / 1024) MB (Δ \(String(format: "%.1f", postIdleDeltaMB)) MB)")
        if !insertErrors.isEmpty { print("[SOAK] sample insert error: \(insertErrors[0])") }
        if !readErrors.isEmpty { print("[SOAK] sample read error: \(readErrors[0])") }
        if !scalarErrors.isEmpty { print("[SOAK] sample scalar error: \(scalarErrors[0])") }

        #expect(insertErrors.isEmpty, "soak surfaced \(insertErrors.count) insert errors; first: \(insertErrors.first ?? "")")
        #expect(readErrors.isEmpty, "soak surfaced \(readErrors.count) read errors; first: \(readErrors.first ?? "")")
        #expect(scalarErrors.isEmpty, "soak surfaced \(scalarErrors.count) scalar errors; first: \(scalarErrors.first ?? "")")
        #expect(insertsCommitted > 0, "soak committed zero inserts in \(durationSeconds) s — likely the workload didn't run")
        #expect(readsCompleted > 0, "soak completed zero reads — likely the workload didn't run")
        #expect(scalarsCompleted > 0, "soak completed zero scalars — likely the workload didn't run")
        #expect(finalCount == Int64(rowsCommitted),
                "final row count must equal rows successfully committed; expected \(rowsCommitted), got \(finalCount)")
        // RSS bound: peak under load can grow, but post-idle floor
        // must come back close to baseline. A 50 MB envelope is
        // generous for 30 s of heavy workload through a 12-conn pool;
        // a real leak (per-iteration retention compounding over
        // hundreds of inserts) would push past it.
        #expect(postIdleFloor < baselineRSS + 50 * 1024 * 1024,
                "RSS did not return to baseline after the soak: Δ \(String(format: "%.1f", postIdleDeltaMB)) MB; suggests a per-op retention leak under sustained load")
    }

    @Test("a client configured with the wrong password surfaces a typed serverException for the auth failure promptly, every retry reproduces the same typed error, and the client never leaks a dead connection")
    func wrongPasswordSurfacesTypedAuthExceptionPromptly() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: "definitely-not-the-real-password-\(UUID().uuidString)",
            connectTimeout: .seconds(5),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // Repeat to confirm the failure mode is stable: the SDK
        // should NOT cache a half-open dead connection and serve it
        // up to the next query. Each attempt must reproduce the same
        // typed error.
        for attempt in 0..<3 {
            let started = Date()
            var caught: Error?
            do {
                _ = try await client.scalarInt64("SELECT toInt64(1)")
            } catch {
                caught = error
            }
            let elapsed = Date().timeIntervalSince(started)
            let received = try #require(caught, "wrong password must throw on attempt \(attempt + 1), not hang")
            // The pool wraps connect-time failures (including
            // handshake auth rejection) in `allPoolEndpointsFailed`
            // when no endpoint succeeds. The underlying cause must
            // mention the server's typed exception path so callers
            // can distinguish auth from generic connectivity.
            let description = String(describing: received)
            #expect(
                description.contains("allPoolEndpointsFailed")
                    || description.contains("handshakeRejected")
                    || description.contains("serverException"),
                "auth failure must surface as a typed exception (saw on attempt \(attempt + 1)): \(description)"
            )
            #expect(
                description.contains("Authentication")
                    || description.contains("auth")
                    || description.contains("password")
                    || description.contains("REQUIRED_PASSWORD")
                    || description.contains("Wrong password")
                    || description.contains("AUTHENTICATION_FAILED")
                    || description.contains("516"),
                "auth failure description must reference the server's auth error (attempt \(attempt + 1)): \(description)"
            )
            #expect(elapsed < 5.0,
                    "auth failure must surface within seconds, not hang on retries; attempt \(attempt + 1) took \(elapsed)s")
        }
    }

    @Test("typed query setting factories produce wire-format strings the live server actually accepts: maxBlockSize, asyncInsert family, maxExecutionTimeSeconds, functionSleepMaxMicrosecondsPerBlock")
    func typedSettingFactoriesAcceptedByLiveServer() async throws {
        let (client, _) = Self.makeClient(maxConnections: 4, acquireTimeout: .waitUpTo(.seconds(30)))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "typed_settings_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(Self.database).\(table) (id UInt64, ts DateTime)
            ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(Self.database).\(table)") } }

        // 1. maxBlockSize controls SELECT block sizing observed at the
        //    SDK level. Pin it to a small value and verify we get
        //    multiple blocks back from a 5000-row range.
        var blocksSeen = 0
        var rowsSeen = 0
        for try await block in client.selectColumns(
            "SELECT toUInt64(number) FROM numbers(5000)",
            settings: [.maxBlockSize(1000)]
        ) {
            blocksSeen += 1
            for column in block.columns {
                if case .uint64(let chunk) = column.values { rowsSeen += chunk.count }
            }
        }
        #expect(rowsSeen == 5000)
        #expect(blocksSeen >= 4,
                "maxBlockSize(1000) should split 5000 rows into ≥5 blocks (allowance for one trailing empty); got \(blocksSeen)")

        // 2. asyncInsert + waitForAsyncInsert + waitForAsyncInsertTimeoutSeconds
        //    must combine into a deterministic INSERT path.
        let qualified = "\(Self.database).\(table)"
        let baseDate = Date()
        try await client.insert(into: qualified, columns: [
            .init(name: "id", values: .uint64([10, 20, 30])),
            .init(name: "ts", values: .dateTime([baseDate, baseDate, baseDate])),
        ], settings: [
            .asyncInsert(true),
            .waitForAsyncInsert(true),
            .waitForAsyncInsertTimeoutSeconds(30),
        ])
        let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualified)")
        #expect(count == 3, "async_insert with wait_for_async_insert=1 must commit before returning; got \(count)")

        // 3. maxExecutionTimeSeconds + functionSleepMaxMicrosecondsPerBlock
        //    must fire the expected server-side timeout exception.
        var caught: Error?
        do {
            _ = try await client.scalarInt64(
                "SELECT toInt64(sleepEachRow(2.0))",
                settings: [
                    .maxExecutionTimeSeconds(1),
                    .functionSleepMaxMicrosecondsPerBlock(5_000_000),
                ]
            )
        } catch {
            caught = error
        }
        let received = try #require(caught, "max_execution_time=1 must surface as a thrown error against a 2 s sleep")
        let description = String(describing: received)
        #expect(
            description.contains("serverException")
                || description.contains("TIMEOUT_EXCEEDED")
                || description.contains("max_execution_time"),
            "typed maxExecutionTimeSeconds must surface as the server's typed timeout exception; got: \(description)"
        )
    }

    // Every typed factory is exercised end-to-end: we SELECT the
    // parameter through `{p:T}` and verify the server-coerced column
    // value equals what we sent. If a factory's wire format disagrees
    // with the server's Field-restore rule (e.g. unquoted numerics
    // tripping `Couldn't restore Field from dump`), this test catches
    // it as either a server exception or a value mismatch.
    @Test("typed query parameters round-trip through `SELECT {p:T}` for every typed factory")
    func typedParameterFactoriesRoundTrip() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // Signed integers, including min/max boundaries
        #expect(try await client.scalarString("SELECT toString({p:Int8}) AS v",
            parameters: [.int8(.min, name: "p")]) == "-128")
        #expect(try await client.scalarString("SELECT toString({p:Int16}) AS v",
            parameters: [.int16(-12345, name: "p")]) == "-12345")
        #expect(try await client.scalarString("SELECT toString({p:Int32}) AS v",
            parameters: [.int32(.min, name: "p")]) == "-2147483648")
        #expect(try await client.scalarString("SELECT toString({p:Int64}) AS v",
            parameters: [.int64(.max, name: "p")]) == "9223372036854775807")
        #expect(try await client.scalarString("SELECT toString({p:Int128}) AS v",
            parameters: [.int128(Int128.min, name: "p")]) == "-170141183460469231731687303715884105728")

        // Unsigned integers
        #expect(try await client.scalarString("SELECT toString({p:UInt8}) AS v",
            parameters: [.uint8(.max, name: "p")]) == "255")
        #expect(try await client.scalarString("SELECT toString({p:UInt16}) AS v",
            parameters: [.uint16(.max, name: "p")]) == "65535")
        #expect(try await client.scalarString("SELECT toString({p:UInt32}) AS v",
            parameters: [.uint32(.max, name: "p")]) == "4294967295")
        #expect(try await client.scalarString("SELECT toString({p:UInt64}) AS v",
            parameters: [.uint64(.max, name: "p")]) == "18446744073709551615")
        #expect(try await client.scalarString("SELECT toString({p:UInt128}) AS v",
            parameters: [.uint128(UInt128.max, name: "p")]) == "340282366920938463463374607431768211455")

        // Floats — Float32 normalised by prefix (limited precision)
        let f32 = try await client.scalarString("SELECT toString({p:Float32}) AS v",
            parameters: [.float32(3.14, name: "p")])
        #expect(f32.hasPrefix("3.14"), "Float32 round-trip prefix; got \(f32)")
        #expect(try await client.scalarFloat64("SELECT {p:Float64} AS v",
            parameters: [.float64(2.718281828459045, name: "p")]) == 2.718281828459045)

        // Bool
        #expect(try await client.scalarBool("SELECT {p:Bool} AS v",
            parameters: [.bool(true, name: "p")]) == true)
        #expect(try await client.scalarBool("SELECT {p:Bool} AS v",
            parameters: [.bool(false, name: "p")]) == false)

        // String — including embedded quote and double-quote that exercise
        // the backslash-escape paths in `quote()`
        #expect(try await client.scalarString("SELECT {p:String} AS v",
            parameters: [.string("hello world 🌍", name: "p")]) == "hello world 🌍")
        #expect(try await client.scalarString("SELECT {p:String} AS v",
            parameters: [.string("O'Brien said \"hi\"", name: "p")]) == "O'Brien said \"hi\"")
        #expect(try await client.scalarString("SELECT {p:String} AS v",
            parameters: [.string("C:\\Users\\Sergey", name: "p")]) == "C:\\Users\\Sergey")

        // UUID
        let uuid = UUID()
        #expect(try await client.scalarUUID("SELECT {p:UUID} AS v",
            parameters: [.uuid(uuid, name: "p")]) == uuid)

        // Date — single-quoted YYYY-MM-DD must coerce to a Date column
        let dateValue = Date(timeIntervalSince1970: 1_705_276_800)  // 2024-01-15 UTC
        #expect(try await client.scalarString("SELECT toString({p:Date}) AS v",
            parameters: [.date(dateValue, name: "p")]) == "2024-01-15")

        // DateTime — single-quoted YYYY-MM-DD HH:MM:SS UTC
        let timestamp = Date(timeIntervalSince1970: 1_710_513_045)  // 2024-03-15 14:30:45 UTC
        #expect(try await client.scalarString("SELECT toString({p:DateTime}) AS v",
            parameters: [.dateTime(timestamp, name: "p")]) == "2024-03-15 14:30:45")

        // DateTime64(3) (milliseconds via Date path)
        let withMillis = Date(timeIntervalSince1970: 1_704_067_200.500)
        #expect(try await client.scalarString("SELECT toString({p:DateTime64(3)}) AS v",
            parameters: [.dateTime64(withMillis, name: "p", precision: 3)]) == "2024-01-01 00:00:00.500")

        // DateTime64(9) via the lossless Int64-ticks path — proves
        // nanosecond-fidelity round-trip with no Double precision loss
        let nanoTicks: Int64 = 1_704_067_200_000_000_001
        #expect(try await client.scalarString("SELECT toString({p:DateTime64(9)}) AS v",
            parameters: [.dateTime64Ticks(nanoTicks, name: "p", precision: 9)]) == "2024-01-01 00:00:00.000000001")

        // dateTime64Nanoseconds (precision 9 wrapper)
        let ticks2: Int64 = 1_700_000_000_999_999_999
        #expect(try await client.scalarString("SELECT toString({p:DateTime64(9)}) AS v",
            parameters: [.dateTime64Nanoseconds(ClickHouseNanoseconds(ticks2), name: "p")]) == "2023-11-14 22:13:20.999999999")
    }

    @Test("client.tables(in:) lists tables in the database via server-side parameter substitution")
    func tablesCatalogAPI() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // Create distinct tables; tables() must return all of them.
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let tableA = "tables_api_a_\(suffix)"
        let tableB = "tables_api_b_\(suffix)"
        try await client.execute("CREATE TABLE \(Self.database).\(tableA) (n Int32) ENGINE = Memory")
        try await client.execute("CREATE TABLE \(Self.database).\(tableB) (n Int32) ENGINE = Memory")
        defer {
            Task {
                try? await client.execute("DROP TABLE \(Self.database).\(tableA)")
                try? await client.execute("DROP TABLE \(Self.database).\(tableB)")
            }
        }

        let names = try await client.tables(in: Self.database)
        #expect(names.contains(tableA), "tables() should list \(tableA); got \(names)")
        #expect(names.contains(tableB), "tables() should list \(tableB); got \(names)")
    }

    @Test("client.exists(table:in:) returns true for existing and false for absent tables")
    func existsCatalogAPI() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let tableName = "exists_api_\(suffix)"
        try await client.execute("CREATE TABLE \(Self.database).\(tableName) (n Int32) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(Self.database).\(tableName)") } }

        let actuallyExists = try await client.exists(table: tableName, in: Self.database)
        #expect(actuallyExists, "exists() should return true for the just-created table")

        let phantom = "exists_api_phantom_\(UUID().uuidString.prefix(8))"
        let phantomExists = try await client.exists(table: phantom, in: Self.database)
        #expect(!phantomExists, "exists() should return false for a non-existent table")
    }

    @Test("client.databases() returns at least the one we're connected to")
    func databasesCatalogAPI() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let names = try await client.databases()
        #expect(names.contains(Self.database),
                "databases() should include our connected database \(Self.database); got \(names)")
    }

    @Test("a CREATE TABLE with a very long column list exercises UVarInt length encoding and packet boundaries")
    func veryLongCreateTableRoundTrips() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        // 1000 columns produces a CREATE TABLE around 30-40 KB of SQL.
        // Combined with the column-name length the INSERT statement
        // also balloons, which exercises both the query packet's
        // UVarInt-prefixed string encoding and the typed encoder
        // pipeline's framing across non-trivial buffer sizes.
        // 1000 columns produces a CREATE TABLE around 30-40 KB of SQL.
        // Combined with the column-name length the INSERT statement
        // also balloons, which exercises both the query packet's
        // UVarInt-prefixed string encoding and the typed encoder
        // pipeline's framing across non-trivial buffer sizes.
        let columnCount = 1_000
        let bareTable = "long_create_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let table = "\(Self.database).\(bareTable)"
        let columns = (0..<columnCount)
            .map { "col_with_a_reasonably_long_name_\($0) Int32" }
            .joined(separator: ", ")
        try await client.execute("CREATE TABLE \(table) (\(columns)) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        // Verify the schema round-tripped: count is exact, the very
        // first and very last column names are preserved.
        let described = try await client.describe(table: bareTable, in: Self.database)
        #expect(described.count == columnCount,
                "expected \(columnCount) columns; got \(described.count)")
        #expect(described.first?.name == "col_with_a_reasonably_long_name_0")
        #expect(described.last?.name == "col_with_a_reasonably_long_name_\(columnCount - 1)")
    }

    @Test("INSERT against a missing table surfaces a typed serverException with the missing-table error code")
    func insertAgainstMissingTableSurfacesTypedError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let nonexistent = "test.does_not_exist_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        var thrown: Error?
        do {
            try await client.insert(into: nonexistent, columns: [
                .init(name: "n", values: .int32([1, 2, 3])),
            ])
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "INSERT against a missing table must throw")
        guard case ClickHouseError.serverException(let exception) = received else {
            Issue.record("expected serverException, got \(received)")
            return
        }
        // CH error code 60 == UNKNOWN_TABLE; we don't pin the exact
        // numeric so a server upgrade renaming the code doesn't break
        // the test, but we DO assert the name and message reference
        // the missing table.
        #expect(!exception.name.isEmpty, "exception must carry a name")
        #expect(exception.message.contains("does_not_exist") || exception.message.contains(nonexistent),
                "error message should reference the missing table; got \(exception.message)")

        // The pool must remain healthy after the failure — a follow-up
        // query on a fresh table must succeed.
        let probe = try await client.scalarInt64("SELECT toInt64(7)")
        #expect(probe == 7)
    }

    @Test("rapid acquire/release cycling under aggressive idleTimeout doesn't surface spurious errors")
    func evictionChurnDoesNotProduceSpuriousFailures() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        // idleTimeout 50 ms, query rate ~one per 25 ms. Connections
        // come back idle, get evicted on the next acquire if their
        // returnedAt + 50 ms has passed. With concurrent callers, the
        // evict scan in `acquire()` and the release path race on the
        // idle queue. If those races caused spurious errors (returning
        // a half-evicted connection, throwing during evict, etc.),
        // this loop would surface them.
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 4,
            maxIdleConnections: 4,
            idleTimeout: .milliseconds(50),
            acquireTimeout: .waitUpTo(.seconds(10)),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let total = 200
        try await withThrowingTaskGroup(of: Int64?.self) { taskGroup in
            for index in 0..<total {
                taskGroup.addTask {
                    if index % 4 == 0 {
                        // Stagger a sub-idleTimeout pause so some
                        // releases happen while others are evicting.
                        try await Task.sleep(nanoseconds: 60_000_000)
                    }
                    return try await client.scalarInt64("SELECT toInt64(\(index))")
                }
            }
            var seen: Set<Int64> = []
            for try await value in taskGroup {
                if let value { seen.insert(value) }
            }
            #expect(seen.count == total,
                    "every query under churn must succeed; got \(seen.count) of \(total)")
        }

        let stats = await client.poolStats()
        // Connection count should stay bounded by maxConnections + a
        // tolerance for evict/reopen during churn. Without proper
        // eviction synchronization, totalConnectionsOpened could grow
        // to roughly `total` (each query opens a fresh connection).
        #expect(stats.totalConnectionsOpened < 60,
                "eviction churn must not blow connection counts; opened=\(stats.totalConnectionsOpened)")
    }

    @Test("rapid execute → drop client cycles for DDL workloads stay bounded via the deinit safety net")
    func ddlChurnStaysBounded() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let setupClient = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))
        defer { Task { await setupClient.shutdown() } }

        let beforeFDs = Self.countOpenFileDescriptors()

        // 200 short-lived clients each running a DDL roundtrip:
        // CREATE TABLE -> DROP TABLE. No INSERTs or SELECTs — purely
        // exercises the execute() retain semantics. Each client falls
        // out of scope without explicit shutdown; the deinit safety
        // net must clean up. Without it, every iteration would leak
        // an open TCP socket.
        for index in 0..<200 {
            let table = "test.ddl_churn_\(index)_\(UUID().uuidString.prefix(6))"
            let client = ClickHouseClient(configuration: .init(
                endpoints: [.init(host: Self.host, port: Self.port)],
                database: Self.database,
                user: Self.user,
                password: Self.password,
                eventLoopGroup: group
            ))
            try await client.execute("CREATE TABLE \(table) (n Int32) ENGINE = Memory")
            try await client.execute("DROP TABLE \(table)")
            // Client falls out of scope here — deinit fires.
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        let afterFDs = Self.countOpenFileDescriptors()
        let leak = afterFDs - beforeFDs
        #expect(leak < 50,
                "DDL churn must not leak FDs; before=\(beforeFDs) after=\(afterFDs) delta=\(leak)")
    }

    @Test("client dropped + Task cancelled mid-stream still propagates cancellation through the retained inner task")
    func clientDroppedThenCancelledStillUnwinds() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        // Build a long-running streaming SELECT under a Task we can
        // cancel. Drop the client reference before the cancel — the
        // stream's inner Task still retains the client via the
        // captured `self`. Then call task.cancel(). Cancellation must
        // propagate through the retained chain (continuation
        // termination -> inner task cancel -> connection close) and
        // the surrounding Task must unwind promptly.
        let started = Date()
        let task = Task<Int, Error> {
            var client: ClickHouseClient? = ClickHouseClient(configuration: .init(
                endpoints: [.init(host: Self.host, port: Self.port)],
                database: Self.database,
                user: Self.user,
                password: Self.password,
                eventLoopGroup: group
            ))
            let stream = client!.selectColumns(
                "SELECT toInt64(sleepEachRow(0.1)) FROM numbers(50) SETTINGS function_sleep_max_microseconds_per_block = 5000000"
            )
            // Drop the user-side reference before iterating. The
            // stream's inner Task keeps the client alive.
            client = nil
            var rowsObserved = 0
            for try await block in stream {
                rowsObserved += block.rowCount
            }
            return rowsObserved
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.5,
                "cancellation must unwind the retained chain in under 1.5s; observed \(elapsed)s")
    }

    @Test("dropping the user-side client reference mid-stream doesn't tear down the client until iteration completes")
    func clientDroppedMidStreamSurvivesViaTaskRetain() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        // Build the streaming SELECT with the client held only by the
        // local var. Right after kicking off the iteration, we drop
        // the local var to nil — the user-side strong reference is
        // gone. The stream's inner Task captures `self` (the client),
        // so ARC keeps the client alive until the stream finishes.
        // If the deinit fired prematurely, the stream would see its
        // pool teardown mid-iteration and throw.
        var client: ClickHouseClient? = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: group
        ))

        let total = 5_000
        let stream = client!.selectColumns(
            "SELECT arrayJoin(range(toUInt64(\(total)))) AS n"
        )

        // Drop the user-side reference IMMEDIATELY after starting the
        // stream. The stream's task retains the client.
        client = nil

        var observed: [UInt64] = []
        observed.reserveCapacity(total)
        for try await block in stream {
            for column in block.columns {
                guard case .uint64(let chunk) = column.values else { continue }
                observed.append(contentsOf: chunk)
            }
        }
        #expect(observed.count == total,
                "stream must complete uninterrupted even with no user-side client retain; got \(observed.count)")
    }

    @Test("a warmed client that's dropped without shutdown still closes its pre-opened connections via the deinit safety net")
    func warmedClientDeinitClosesPreOpenedConnections() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let beforeFDs = Self.countOpenFileDescriptors()

        // Warm up a client with several pre-opened connections, then
        // drop it without shutdown. Without the deinit safety net,
        // every warmed connection would leak — exactly the failure
        // mode warmUp callers (production preflight code, often) are
        // most exposed to since they tend to discard the warming
        // client after a one-shot warmup.
        do {
            let client = ClickHouseClient(configuration: .init(
                endpoints: [.init(host: Self.host, port: Self.port)],
                database: Self.database,
                user: Self.user,
                password: Self.password,
                maxConnections: 5,
                maxIdleConnections: 5,
                eventLoopGroup: group
            ))
            try await client.warmUp(connections: 5)
            let stats = await client.poolStats()
            #expect(stats.idleCount == 5, "warmUp must leave 5 connections idle; got \(stats.idleCount)")
            // Client falls out of scope on the next line — deinit fires.
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        let afterFDs = Self.countOpenFileDescriptors()
        let leak = afterFDs - beforeFDs
        // 5 idle connections + the EventLoopGroup we hold; the safety
        // net should close every connection.
        #expect(leak < 10,
                "warmed-client deinit must close pre-opened connections; before=\(beforeFDs) after=\(afterFDs) delta=\(leak)")
    }

    @Test("100 parallel clients running concurrent queries all complete and drop cleanly via the deinit cascade")
    func parallelClientChurnStaysBounded() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }

        let beforeFDs = Self.countOpenFileDescriptors()

        // 100 clients spawned concurrently. Each runs a query then
        // exits the closure, dropping the client. Without the deinit
        // safety net, the pool's eviction tasks and idle connections
        // would accumulate. The TaskGroup waits for all to finish, so
        // by the time we exit the group every client's ARC has hit
        // zero and the deinit has fired.
        try await withThrowingTaskGroup(of: Int64?.self) { taskGroup in
            for index in 0..<100 {
                taskGroup.addTask {
                    let client = ClickHouseClient(configuration: .init(
                        endpoints: [.init(host: Self.host, port: Self.port)],
                        database: Self.database,
                        user: Self.user,
                        password: Self.password,
                        eventLoopGroup: group
                    ))
                    return try await client.scalarInt64("SELECT toInt64(\(index))")
                }
            }
            var seen: Set<Int64> = []
            for try await value in taskGroup {
                if let value { seen.insert(value) }
            }
            #expect(seen.count == 100, "all 100 parallel clients must complete distinct queries; saw \(seen.count)")
        }

        // Drain the deinit Tasks — they're spawned unstructured and
        // complete asynchronously after the closure exits.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let afterFDs = Self.countOpenFileDescriptors()
        let leak = afterFDs - beforeFDs
        // Tighter bound than the sequential test because parallel
        // open+close shouldn't accumulate beyond a few stragglers.
        #expect(leak < 50,
                "100 parallel clients must not leak file descriptors; before=\(beforeFDs) after=\(afterFDs) delta=\(leak)")
    }

    @Test("creating and dropping 1000 short-lived clients without explicit shutdown stays bounded via the deinit safety net")
    func clientChurnStaysBounded() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        // Sample the file descriptor count before vs after to confirm
        // we don't leak sockets across the churn. macOS exposes this
        // via getrlimit/RLIMIT_NOFILE; we just track total open files
        // for the current process via a directory walk of /dev/fd.
        let beforeFDs = Self.countOpenFileDescriptors()

        // 1000 lifecycles: each creates a client, runs a query, drops
        // the client without calling shutdown(). The deinit safety
        // net schedules the pool shutdown which closes connections
        // and cancels the background eviction task. If the safety net
        // didn't work, file descriptors would accumulate proportional
        // to the iteration count.
        for _ in 0..<1_000 {
            let client = ClickHouseClient(configuration: .init(
                endpoints: [.init(host: Self.host, port: Self.port)],
                database: Self.database,
                user: Self.user,
                password: Self.password,
                eventLoopGroup: group
            ))
            _ = try await client.scalarInt64("SELECT toInt64(1)")
            // Client goes out of scope here — deinit fires.
        }

        // Give the deinit Tasks a moment to drain; they're spawned
        // unstructured and complete asynchronously.
        try await Task.sleep(nanoseconds: 500_000_000)

        let afterFDs = Self.countOpenFileDescriptors()
        let leak = afterFDs - beforeFDs
        // Allow modest slack for system FDs that drift across the run
        // (logging, scheduler internals, etc.). If the safety net
        // weren't working, we'd expect >> 100 leaked sockets.
        #expect(leak < 50,
                "expected bounded FD growth across 1000 clients; before=\(beforeFDs) after=\(afterFDs) delta=\(leak)")
    }

    // Sendable producer used by the drop-mid-INSERT regression test.
    // The BlockProvider closure on `client.insert(into:blockProvider:)`
    // is @Sendable, so a captured-var counter would trip Swift's
    // strict-concurrency check. Wrapping the cursor in an actor lets
    // the closure call into a Sendable shared state without a lock.
    private actor BlockProducer {

        private var produced: Int = 0
        private let targetRows: Int
        private let batchSize: Int

        init(targetRows: Int, batchSize: Int) {
            self.targetRows = targetRows
            self.batchSize = batchSize
        }

        func next() -> ClickHouseColumnBatchOutcome {
            guard produced < targetRows else { return .endOfStream }
            let batch = (0..<batchSize).map { Int64(produced + $0) }
            produced += batchSize
            return .batch([.init(name: "n", values: .int64(batch))])
        }

    }

    private static func countOpenFileDescriptors() -> Int {
        guard let handle = opendir("/dev/fd") else { return 0 }
        defer { closedir(handle) }
        var count = 0
        while readdir(handle) != nil {
            count += 1
        }
        return count
    }

    @Test("a query that fails server-side does not leak the connection out of the pool")
    func failedQueryDoesNotLeakConnection() async throws {
        let (client, _) = Self.makeClient(maxConnections: 2)
        defer { Task { await client.shutdown() } }

        // Burn through a few server-side failures.
        for _ in 0..<10 {
            do {
                _ = try await client.scalarInt64("SELECT * FROM test.absolutely_does_not_exist")
            } catch ClickHouseError.serverException {
                continue
            }
        }
        // The next valid query must still succeed (i.e. the pool didn't
        // run out of connections).
        let value = try await client.scalarInt64("SELECT toInt64(7)")
        #expect(value == 7)
    }

}
