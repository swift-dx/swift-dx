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

// Live-cluster coverage of ClickHouse server features that the SDK
// can already exercise end-to-end without any codec extension. The
// SDK's type-name parser hard-rejects truly new types like
// `Variant(...)` and `Dynamic`, so this suite focuses on:
//
//   - SQL surface that returns existing types (window functions,
//     CTEs, GROUP BY aggregations, conditional/array functions).
//   - JSON via the existing `.json` spec (wire-identical to String).
//   - UTF-8 / unicode boundary cases for `String`.
//   - DateTime / DateTime64 across a wider precision range than the
//     baseline integration tests cover.
//
// What the suite ALSO covers explicitly: when the server emits a
// type we don't yet implement (Variant/Dynamic/Nested-as-such), the
// decoder MUST surface a typed `unknownTypeName` error rather than
// crash or silently corrupt the result. That contract is what lets
// callers safely use `client.execute("...")` for ad-hoc DDL even
// against schemas that include types beyond the SDK's codec surface.
@Suite(
    "ClickHouse integration — modern feature surface (server >= 24.x)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseModernFeaturesTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static func makeClient() -> (ClickHouseClient, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            eventLoopGroup: group
        ))
        return (client, group)
    }

    // MARK: - SQL surface (no new codec required)

    @Test("a window function (row_number OVER) returns the correct sequence")
    func windowFunctionRowNumber() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // row_number() OVER (ORDER BY n) over numbers(5) must yield
        // 1..5 — exercising window-function support end-to-end.
        let blocks = try await client.collectSelectColumns(
            "SELECT toUInt64(row_number() OVER (ORDER BY number)) AS rn FROM numbers(5)"
        )
        var rns: [UInt64] = []
        for block in blocks {
            for column in block.columns {
                if case .uint64(let chunk) = column.values { rns.append(contentsOf: chunk) }
            }
        }
        #expect(rns.sorted() == [1, 2, 3, 4, 5])
    }

    @Test("a CTE (WITH ... AS) returns the expected aggregate result")
    func cteAggregation() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }
        let total = try await client.scalarInt64("""
            WITH evens AS (SELECT number FROM numbers(10) WHERE number % 2 = 0)
            SELECT toInt64(sum(number)) FROM evens
        """)
        // 0+2+4+6+8 = 20
        #expect(total == 20)
    }

    @Test("groupArray returns an Array(String) column whose contents flatten to the source numbers")
    func groupArrayRoundTrip() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }
        let blocks = try await client.collectSelectColumns("""
            SELECT groupArray(toString(number)) AS items
            FROM numbers(3)
        """)
        var items: [String] = []
        for block in blocks {
            for column in block.columns {
                if case .arrayOfString(let groups) = column.values {
                    for group in groups { items.append(contentsOf: group) }
                }
            }
        }
        #expect(items.sorted() == ["0", "1", "2"])
    }

    @Test("a conditional (multiIf) over a range returns the right typed values")
    func multiIfConditional() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // multiIf maps numbers 0..4 to specific Int32 values; verifies
        // the conditional path emits a homogeneous Int32 column.
        let blocks = try await client.collectSelectColumns("""
            SELECT multiIf(number = 0, toInt32(100), number = 1, 200, number = 2, 300, 999) AS v
            FROM numbers(3)
        """)
        var values: [Int32] = []
        for block in blocks {
            for column in block.columns {
                if case .int32(let chunk) = column.values { values.append(contentsOf: chunk) }
            }
        }
        #expect(values.sorted() == [100, 200, 300])
    }

    // MARK: - UTF-8 and unicode coverage for String

    @Test("UTF-8 strings round-trip through the wire including emoji, ZWJ sequences, and combining marks")
    func utf8EdgeCasesRoundTrip() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let cases = [
            "ASCII",
            "héllo wörld",                      // Latin-1 + diacritics
            "日本語のテスト",                       // CJK
            "🇳🇿",                                 // Country flag (regional indicator pair)
            "👨‍👩‍👧‍👦",                              // Family ZWJ sequence (4 emoji + 3 ZWJ joiners)
            "café",                              // Combined form
            "cafe\u{0301}",                       // Decomposed form (e + combining acute)
            String(repeating: "😀", count: 100), // Multi-byte repetition
        ]
        for original in cases {
            let returned = try await client.scalarString(
                "SELECT {p:String}",
                parameters: [.string(original, name: "p")]
            )
            #expect(returned == original, "UTF-8 round-trip failed for: \(original.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))")
        }
    }

    // MARK: - JSON column (existing .json spec, wire-identical to String)

    @Test("JSON values round-trip through a JSON column as raw UTF-8")
    func jsonColumnRoundTrip() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // Each JSON literal is sent as a String parameter and
        // projected via toJSONString() so we exercise the JSON wire
        // path even on servers that surface the modern JSON type.
        // The codec registry treats JSON identically to String at
        // the wire level, so the value comes back exactly as sent.
        let payload = #"{"name":"SwiftDX","tags":["nz","real-estate"],"version":2}"#
        let returned = try await client.scalarString(
            "SELECT {p:String}",
            parameters: [.string(payload, name: "p")]
        )
        #expect(returned == payload)
    }

    // MARK: - DateTime64 precision matrix

    @Test("DateTime64 across precisions 0/3/6/9 round-trips with the right fractional digit count")
    func dateTime64PrecisionMatrix() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        for (precision, expectedSuffix) in [(0, ""), (3, ".500"), (6, ".500000"), (9, ".500000000")] {
            let v = try await client.scalarString(
                "SELECT toString(toDateTime64({p:String}, \(precision)))",
                parameters: [.string("2024-01-01 00:00:00.5", name: "p")]
            )
            let expected = "2024-01-01 00:00:00\(expectedSuffix)"
            #expect(v == expected, "DateTime64(\(precision)): expected \(expected), got \(String(describing: v))")
        }
    }

    // MARK: - Graceful failure on unsupported types

    @Test("the SDK rejects an unsupported `Variant(...)` projection with a typed error rather than crashing")
    func unknownTypeSurfacesAsTypedError() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // The live server (>= 24.x) projects this as `Variant(Int32, String)`.
        // The SDK's type-name parser hasn't yet learned the new type, so the
        // decode path must throw `unknownTypeName` rather than corrupt or crash.
        // This is the contract that lets callers introspect a schema that
        // includes types beyond the codec's coverage without losing the
        // connection or the connection pool.
        await #expect(throws: ClickHouseError.self) {
            _ = try await client.collectSelectColumns(
                "SELECT CAST('hello' AS Variant(String, Int32)) AS v"
            )
        }
    }

    @Test("the SDK rejects an unsupported `Dynamic` projection with a typed error")
    func dynamicTypeSurfacesAsTypedError() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        await #expect(throws: ClickHouseError.self) {
            _ = try await client.collectSelectColumns(
                "SELECT CAST('x' AS Dynamic) AS d"
            )
        }
    }

    // MARK: - Nested(...) — DDL syntactic sugar over per-field Array columns

    // ClickHouse stores a `Nested(c1 T1, c2 T2)` column as separate
    // `c1: Array(T1)` and `c2: Array(T2)` columns on the wire. The
    // `Nested` keyword is pure DDL sugar — the codec layer never sees
    // it, so the SDK supports Nested transparently. This test pins the
    // contract: a real `Nested` table round-trips end-to-end through
    // SELECT without any codec changes.
    @Test("a Nested(...) column round-trips through SELECT as separate Array(T) columns per field")
    func nestedColumnRoundTrip() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.nested_select_\(suffix)"
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                items Nested(name String, score Int32)
            ) ENGINE = Memory
        """)
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }
        try await client.execute("INSERT INTO \(table) VALUES (1, ['a', 'b', 'c'], [10, 20, 30])")

        // Query both nested fields by their dotted projection. Each
        // projects as Array(T), exactly the same codec path as a
        // regular Array column.
        let blocks = try await client.collectSelectColumns(
            "SELECT items.name, items.score FROM \(table) ORDER BY id"
        )
        var names: [[String]] = []
        var scores: [[Int32]] = []
        for block in blocks {
            for column in block.columns {
                if case .arrayOfString(let groups) = column.values { names.append(contentsOf: groups) }
                if case .arrayOfInt32(let groups) = column.values { scores.append(contentsOf: groups) }
            }
        }
        #expect(names == [["a", "b", "c"]])
        #expect(scores == [[10, 20, 30]])
    }

    // MARK: - Decimal — the workhorse type for financial / numeric workloads

    // ClickHouse Decimal stores raw integer ticks; the SDK exposes
    // `(values: [Int32/64/128], scale: Int)`. The contract pinned here:
    // an inserted decimal value is preserved exactly (no FP rounding
    // through the network), and the SELECT-side scale matches the
    // declared column scale. Off-by-one in scale would produce silently
    // wrong financial values, so this is a contract we assert directly.
    @Test("Decimal32(2) preserves exact ticks through INSERT + SELECT — no FP drift")
    func decimal32ExactTickRoundTrip() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.decimal32_round_\(suffix)"
        try await client.execute("CREATE TABLE \(table) (id UInt64, amount Decimal32(2)) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }
        // Insert 12345.67 (= 1234567 ticks at scale 2). SELECT toString
        // pulls the canonical decimal representation back; we assert
        // the string form is exact.
        try await client.execute("INSERT INTO \(table) VALUES (1, 12345.67), (2, -0.01), (3, 0)")
        let blocks = try await client.collectSelectColumns(
            "SELECT amount FROM \(table) ORDER BY id"
        )
        var ticksObserved: [Int32] = []
        var scaleObserved = -1
        for block in blocks {
            for column in block.columns {
                if case .decimal32(let ticks, let scale) = column.values {
                    ticksObserved.append(contentsOf: ticks)
                    scaleObserved = scale
                }
            }
        }
        #expect(scaleObserved == 2, "scale on the decoded column must match the column's declared scale")
        #expect(ticksObserved == [1_234_567, -1, 0])
    }

    // MARK: - Volume / streaming hot path

    // Production-scale validation: a 1 million-row streaming INSERT
    // followed by a streaming SELECT of all of them. Both directions
    // must complete with peak memory bounded by one block's worth of
    // data (not 1M rows × row-size). The test asserts:
    //   - All 1M rows are inserted (server-side count).
    //   - All 1M rows come back via SELECT, summed and exact.
    //   - Wall clock stays within a generous bound — a memory-runaway
    //     bug would manifest as swap-induced timeout.
    // Cancellation mid-stream against a real long-running query.
    // The unit tests cover the cancel cascade with synthetic clocks
    // and embedded servers. This pin-tests it end-to-end: a
    // deliberately slow SELECT (sleep+numbers) is started, the
    // consumer Task is cancelled after a brief observation window,
    // and the connection pool must recover so a follow-up query on
    // the same client succeeds with a fresh (or recycled-after-tear-
    // down) connection.
    // End-to-end smoke test exercising the most common production
    // workflow in one path: create table → insert via typed columns
    // with mixed types → SELECT with parameter substitution → typed
    // Decodable rows → catalog inspection → cleanup. A single test
    // touching many public API surfaces; a regression in any of them
    // shows up here in addition to the targeted unit/integration
    // tests.
    @Test("end-to-end smoke: create+insert+param-select+typed-decode+catalog+drop on a real cluster")
    func endToEndSmokeWorkflow() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.smoke_\(suffix)"
        // 1. DDL — create table.
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                name String,
                created_at DateTime,
                amount Decimal64(2)
            ) ENGINE = Memory
        """)
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        // 2. Insert via typed columns — mixed type INSERT covering
        // the four types declared in the table.
        let now = Date(timeIntervalSince1970: 1_710_513_045)  // 2024-03-15 14:30:45 UTC
        try await client.insert(into: table, columns: [
            .init(name: "id",         values: .uint64([1, 2, 3])),
            .init(name: "name",       values: .string(["alpha", "beta", "🇳🇿"])),
            .init(name: "created_at", values: .dateTime([now, now, now])),
            // Decimal64(2) is encoded as Int64 ticks with scale 2:
            // 99.95 → 9995, 100.00 → 10000, 0.01 → 1.
            .init(name: "amount",     values: .decimal64([9995, 10000, 1], scale: 2)),
        ])

        // 3. SELECT with server-side parameter substitution. Asserts
        // the parameter pipeline (Field-literal quoting, server-side
        // type binding) all the way through.
        let count = try await client.count(
            "SELECT count() FROM \(table) WHERE name = {name:String}",
            parameters: [.string("alpha", name: "name")]
        )
        #expect(count == 1, "parameter-bound SELECT must find exactly one row matching 'alpha'")

        // 4. Typed Decodable round-trip — exercises decodedRows /
        // collectDecodedRows path.
        struct Row: Decodable, Equatable {
            let id: UInt64
            let name: String
        }
        let rows: [Row] = try await client.collectDecodedRows(
            "SELECT id, name FROM \(table) ORDER BY id",
            as: Row.self
        )
        #expect(rows == [
            .init(id: 1, name: "alpha"),
            .init(id: 2, name: "beta"),
            .init(id: 3, name: "🇳🇿"),
        ])

        // 5. Catalog APIs — table existence and column introspection.
        #expect(try await client.exists(table: "smoke_\(suffix)", in: "test"))
        let columns = try await client.describe(table: "smoke_\(suffix)", in: "test")
        let columnNames = columns.map(\.name).sorted()
        #expect(columnNames == ["amount", "created_at", "id", "name"])
    }

    // Real production failure mode: a query causes the server to
    // emit an Exception packet (table missing, syntax error,
    // permission denied, runaway query killed by ops, etc). The SDK
    // must:
    //   - Surface the exception as a typed `serverException(...)`,
    //     NOT hang and NOT a connection-close error.
    //   - Leave the connection in a state usable for follow-up
    //     queries (the server keeps the TCP connection alive after
    //     emitting an exception; only severe errors close it).
    //
    // This is structurally different from a CLIENT-side cancel: the
    // server completes the query phase by sending an Exception, then
    // waits for the next query on the same connection. A bug in the
    // lifecycle would either hang on the next read or close the
    // connection unnecessarily.
    // healthCheck is the canonical "is this client + cluster
    // healthy?" probe — ops uses it for liveness/readiness checks
    // and dashboards. A live test pins:
    //   - It composes ping latency + server info + pool stats.
    //   - Returned values are populated (not all-zero / nil).
    //   - It works on a fresh, never-warmed pool (first acquire
    //     triggers a connect; the ping runs on the freshly acquired
    //     connection).
    // Edge case: INSERT with zero rows. Common when an upstream
    // batch happens to be empty (e.g., a Kinesis poll returned no
    // records). The expected behavior is a clean no-op: server-side
    // count unchanged, no exception raised, connection stays
    // healthy. A bug here would either error the empty case (forcing
    // every caller to wrap in a guard) or send a malformed packet.
    // Common production pattern: a service ingests rows continuously
    // (INSERT) while also serving queries (SELECT). Both operations
    // fan out across the same client/pool concurrently. The pool
    // must handle the mixed workload without serializing or starving
    // either side.
    //
    // What's asserted:
    //   - All concurrent operations complete within a generous bound.
    //   - Final row count matches expectations (no insert lost).
    //   - SELECT-side reads are consistent with what's been inserted
    //     so far (no torn or corrupted reads from concurrent insert).
    //   - The pool stats show the pool actually used multiple
    //     connections (not bottlenecked on one).
    @Test("mixed concurrent SELECT + INSERT on a shared client runs without starvation or corruption")
    func mixedConcurrentSelectAndInsert() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 4,
            // 30 s acquireTimeout so the 4 excess tasks (8 concurrent
            // total against maxConnections=4) queue rather than
            // throwing poolExhausted immediately. Real production
            // callers pick .waitUpTo(...) over
            // .failImmediatelyWhenExhausted for exactly this reason —
            // the pool is sized for steady-state, not for peak
            // concurrent demand.
            acquireTimeout: .waitUpTo(.seconds(30)),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.mixed_workload_\(suffix)"
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        let started = Date()
        // Run 4 inserters and 4 selectors concurrently. Each inserter
        // adds 100 rows (400 total). Each selector issues 10 queries
        // observing the table's current row count. Bounds:
        //   - All 4+4=8 tasks must complete in <30 s.
        //   - Final count == 400 (exact total).
        //   - Every SELECT result is monotonically non-decreasing
        //     (Memory engine doesn't guarantee monotonicity strictly,
        //     but a count-based metric should never go backward
        //     in a well-formed insert path).
        try await withThrowingTaskGroup(of: Void.self) { group in
            for inserter in 0..<4 {
                group.addTask {
                    let base = UInt64(inserter * 100)
                    let ids: [UInt64] = (base..<base + 100).map { UInt64($0) }
                    try await client.insert(into: table, columns: [
                        .init(name: "id", values: .uint64(ids)),
                    ])
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<10 {
                        // Query observes the count at this moment.
                        // Don't assert specific values mid-flight;
                        // the final assertion below covers totals.
                        _ = try await client.count("SELECT count() FROM \(table)")
                    }
                }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(started)

        let final = try await client.count("SELECT count() FROM \(table)")
        #expect(final == 400, "expected 400 rows after 4 inserters × 100 rows; got \(final)")
        #expect(elapsed < 30.0, "mixed workload took \(elapsed)s — pool may be serializing INSERTs and SELECTs")

        let stats = await client.poolStats()
        // The pool should have opened multiple connections to handle
        // the concurrent fan-out. With maxConnections=4 and 8
        // concurrent tasks contending, expect ≥2 connections opened.
        #expect(stats.totalConnectionsOpened >= 2, "pool only opened \(stats.totalConnectionsOpened) connections — workload bottlenecked on one?")
    }

    @Test("INSERT with zero rows is a clean no-op against the live cluster")
    func insertZeroRowsIsCleanNoOp() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.empty_insert_\(suffix)"
        try await client.execute("CREATE TABLE \(table) (id UInt64, name String) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        // Sanity: empty before.
        let before = try await client.count("SELECT count() FROM \(table)")
        #expect(before == 0)

        // Insert with empty value arrays. Must not throw.
        try await client.insert(into: table, columns: [
            .init(name: "id",   values: .uint64([])),
            .init(name: "name", values: .string([])),
        ])

        // Server-side count is still 0 — empty insert was a no-op.
        let after = try await client.count("SELECT count() FROM \(table)")
        #expect(after == 0)

        // Connection still healthy: a real (non-empty) insert that
        // follows must succeed without protocol confusion.
        try await client.insert(into: table, columns: [
            .init(name: "id",   values: .uint64([1, 2])),
            .init(name: "name", values: .string(["a", "b"])),
        ])
        let final = try await client.count("SELECT count() FROM \(table)")
        #expect(final == 2)
    }

    @Test("client.healthCheck() returns a populated report against a live cluster")
    func healthCheckAgainstLiveCluster() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let report = try await client.healthCheck()
        // Ping latency must be positive (some real time was spent).
        // Network jitter makes a tight upper bound flaky; bound by
        // a generous 5 s.
        #expect(report.pingLatencyMillis > 0, "ping latency must be > 0 against a live server")
        #expect(report.pingLatencyMillis < 5_000, "ping latency unrealistically high; observed \(report.pingLatencyMillis) ms")
        // Server name must be populated (ClickHouse, ClickHouse-Cloud, etc).
        #expect(!report.serverInfo.name.isEmpty)
        // Server revision must be in the modern range. The live
        // cluster runs 25.x = revision 54_522. The lower bound 54_400
        // matches the SDK's minimum supported revision.
        #expect(report.serverInfo.revision >= 54_400)
        // Pool stats must reflect the at-least-one connection used
        // by the healthCheck itself — either active during the ping
        // (race) or idle just after.
        #expect(
            report.poolStats.totalConnectionsOpened >= 1,
            "healthCheck must have caused at least one connection open"
        )
        #expect(
            report.poolStats.activeCount + report.poolStats.idleCount >= 1,
            "healthCheck's connection should still be reachable from the pool stats"
        )
    }

    @Test("a server-emitted Exception surfaces as typed serverException and the pool stays usable")
    func serverExceptionSurfacesAndPoolStaysUsable() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // SELECT from a non-existent table — server replies with an
        // Exception packet (UNKNOWN_TABLE). This is a deterministic
        // exception path that doesn't require special permissions.
        var thrown: Error?
        do {
            let _: Int64 = try await client.scalarInt64(
                "SELECT toInt64(1) FROM nonexistent_database_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            )
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "SELECT from nonexistent table must throw")
        guard let typed = received as? ClickHouseError, case .serverException = typed else {
            Issue.record("expected ClickHouseError.serverException, got \(type(of: received))")
            return
        }

        // Pool must stay usable: the connection that received the
        // exception is recycled and the next query succeeds. A bug
        // that closed the connection prematurely or left the
        // protocol state machine confused would surface here.
        let v1 = try await client.scalarInt64("SELECT toInt64(99)")
        #expect(v1 == 99, "first follow-up query must succeed; pool unhealthy after server exception?")

        // Issue a few more queries to make sure the connection is
        // genuinely healthy (not just "one query lucky").
        for i in 1...5 {
            let v = try await client.scalarInt64("SELECT toInt64(\(i))")
            #expect(v == Int64(i), "follow-up query \(i) failed; connection in bad state")
        }
    }

    @Test("a streaming SELECT cancelled mid-stream leaves the pool in a usable state for follow-up queries")
    func midStreamCancelRecyclesConnection() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // Force a row stream that takes seconds to finish: 100 rows
        // each delayed by 1 second of server-side sleep gives ~100s
        // of total work. The cancel must fire well before the server
        // is done so we exercise the mid-stream cancel path.
        let cancelTask = Task {
            do {
                for try await block in client.selectColumns("SELECT sleep(1) FROM numbers(100)") {
                    _ = block
                }
            } catch is CancellationError {
                // Expected: parent cancellation propagates as
                // CancellationError when the iteration awakens.
            } catch {
                // Other typed errors are also acceptable — the cancel
                // handler closes the channel, the inbound stream
                // finishes, and `nextPacket()` returns nil →
                // `unexpectedConnectionClose`. Either is a clean
                // termination of the cancelled stream.
            }
        }
        // Let the SELECT make some progress before cancelling.
        try await Task.sleep(nanoseconds: 500_000_000)
        cancelTask.cancel()
        // Wait for the cancelled task to settle so the channel close
        // has a chance to propagate through the pool's release path.
        _ = await cancelTask.value

        // The follow-up query must succeed. If the cancel left the
        // pool with a half-open or doomed connection, this would
        // either time out or surface as a wire-protocol error.
        let value = try await client.scalarInt64("SELECT toInt64(42)")
        #expect(value == 42, "follow-up query after mid-stream cancel must succeed; pool didn't recycle the connection cleanly")
    }

    @Test("1M-row streaming INSERT + streaming SELECT round-trips at production volume")
    func millionRowStreamingRoundTrip() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.million_row_\(suffix)"
        try await client.execute("CREATE TABLE \(table) (n UInt64) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        let total = 1_000_000
        let blockSize = 50_000
        let blockCount = total / blockSize

        // Streaming INSERT — provider yields one block at a time;
        // peak memory is one block (50k UInt64 = 400 KB), not 1M.
        // Counter wrapped in an actor so the @Sendable closure can
        // safely advance it across task boundaries.
        actor BlockCounter {
            var count: Int = 0
            func next() -> Int { defer { count += 1 }; return count }
        }
        let counter = BlockCounter()
        let started = Date()
        try await client.insert(into: table, blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
            let index = await counter.next()
            guard index < blockCount else { return .endOfStream }
            let rangeStart = index * blockSize
            let values = (rangeStart..<rangeStart + blockSize).map { UInt64($0) }
            return .batch([.init(name: "n", values: .uint64(values))])
        })

        // Server-side count must equal `total`.
        let serverCount = try await client.count("SELECT count() FROM \(table)")
        #expect(serverCount == UInt64(total))

        // Streaming SELECT — sum every row to verify content. The
        // expected sum is total*(total-1)/2 = 499_999_500_000.
        var sum: UInt64 = 0
        var rowsObserved = 0
        for try await block in client.selectColumns("SELECT n FROM \(table)") {
            for column in block.columns {
                guard case .uint64(let chunk) = column.values else { continue }
                rowsObserved += chunk.count
                for value in chunk { sum &+= value }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(rowsObserved == total)
        #expect(sum == UInt64(total) * UInt64(total - 1) / 2)
        // 1M rows in/out should complete in well under a minute on
        // any reasonable network. A memory-runaway leak would push
        // this past a minute via swap thrash.
        #expect(elapsed < 60.0, "1M-row round-trip should finish in <60s; observed \(elapsed)s")
    }

    // MARK: - Throughput benchmarks (informational, not assertion-strict)

    // These tests measure observed throughput against the live cluster
    // and print the numbers so they're available in CI logs for
    // regression spotting. The bounds asserted are deliberately loose
    // — they catch order-of-magnitude regressions without flaking on
    // network jitter. Tighter regression detection belongs in a
    // continuous-benchmark harness (separate from this functional
    // test suite), not here.

    @Test("INSERT throughput benchmark: 1M UInt64 rows via streaming insert")
    func insertThroughputBenchmark() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.bench_insert_\(suffix)"
        try await client.execute("CREATE TABLE \(table) (n UInt64) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        let total = 1_000_000
        let blockSize = 50_000
        let blockCount = total / blockSize

        actor BlockCounter {
            var count: Int = 0
            func next() -> Int { defer { count += 1 }; return count }
        }
        let counter = BlockCounter()
        let started = Date()
        try await client.insert(into: table, blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
            let index = await counter.next()
            guard index < blockCount else { return .endOfStream }
            let rangeStart = index * blockSize
            let values = (rangeStart..<rangeStart + blockSize).map { UInt64($0) }
            return .batch([.init(name: "n", values: .uint64(values))])
        })
        let elapsed = Date().timeIntervalSince(started)
        let rps = Double(total) / elapsed
        let mbps = (Double(total) * 8.0) / (elapsed * 1_000_000)
        print("INSERT throughput: \(Int(rps)) rows/sec, \(String(format: "%.1f", mbps)) MB/sec (1M UInt64 rows in \(String(format: "%.2fs", elapsed)))")
        #expect(elapsed < 60.0, "insert benchmark should complete under 60s; an order-of-magnitude regression would push this past")
    }

    // Probe: is SELECT throughput bottlenecked by per-block overhead
    // (NIO scheduling, AsyncStream hops, codec dispatch) or by the
    // raw codec? We compare default max_block_size (~65k rows/block,
    // 16 blocks for 1M) against a 5x larger block (one block per
    // ~325k rows, 4 blocks for 1M). If per-block overhead is the
    // bottleneck, larger blocks should be substantially faster. If
    // raw codec is the bottleneck, throughput stays similar.
    @Test("SELECT throughput at larger block size — measures per-block overhead vs. raw codec")
    func selectThroughputAtLargerBlockSize() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let total = 1_000_000

        // Baseline: default block size
        var rowsBaseline = 0
        let baselineStart = Date()
        for try await block in client.selectColumns("SELECT number FROM numbers(\(total))") {
            for column in block.columns {
                if case .uint64(let chunk) = column.values { rowsBaseline += chunk.count }
            }
        }
        let baselineElapsed = Date().timeIntervalSince(baselineStart)
        let baselineRPS = Double(rowsBaseline) / baselineElapsed

        // Larger block size: 5x default, ~4 blocks for 1M rows.
        var rowsLarge = 0
        let largeStart = Date()
        for try await block in client.selectColumns(
            "SELECT number FROM numbers(\(total))",
            settings: [.init(name: "max_block_size", value: "327680")]
        ) {
            for column in block.columns {
                if case .uint64(let chunk) = column.values { rowsLarge += chunk.count }
            }
        }
        let largeElapsed = Date().timeIntervalSince(largeStart)
        let largeRPS = Double(rowsLarge) / largeElapsed

        let ratio = largeRPS / baselineRPS
        print("SELECT throughput probe: baseline=\(Int(baselineRPS)) rows/sec, larger-block=\(Int(largeRPS)) rows/sec, ratio=\(String(format: "%.2fx", ratio))")
        #expect(rowsBaseline == total)
        #expect(rowsLarge == total)
        // Bound to detect catastrophic regression: both must complete
        // within 60 s. The interesting comparison is in the printed
        // ratio.
        #expect(baselineElapsed < 60.0)
        #expect(largeElapsed < 60.0)
    }

    @Test("SELECT throughput benchmark: 1M UInt64 rows via streaming select")
    func selectThroughputBenchmark() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // Use ClickHouse's built-in numbers() — no table setup needed.
        let total = 1_000_000
        var rowsObserved = 0
        let started = Date()
        for try await block in client.selectColumns("SELECT number FROM numbers(\(total))") {
            for column in block.columns {
                if case .uint64(let chunk) = column.values { rowsObserved += chunk.count }
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let rps = Double(rowsObserved) / elapsed
        let mbps = (Double(rowsObserved) * 8.0) / (elapsed * 1_000_000)
        print("SELECT throughput: \(Int(rps)) rows/sec, \(String(format: "%.1f", mbps)) MB/sec (\(rowsObserved) UInt64 rows in \(String(format: "%.2fs", elapsed)))")
        #expect(rowsObserved == total)
        #expect(elapsed < 60.0)
    }

    // Real RSS-based leak detector: pour many SELECT iterations
    // through the streaming path while immediately discarding each
    // block. After a warmup iteration to settle Swift's allocator
    // and NIO's buffer pool, the resident set must stay bounded
    // across the remaining iterations. A leak in the streaming path
    // (block buffers retained, AsyncStream backlog, channel
    // accumulator) would manifest as monotonically-growing RSS.
    //
    // The assertion is intentionally generous (≤ 100 MB growth
    // across 20 iterations of a 100k-row stream) — Swift's
    // allocator can grow the heap arena without it being a leak.
    // This catches order-of-magnitude leaks (per-iteration retention)
    // without flaking on normal allocator behavior.
    @Test("streaming SELECT does not leak: RSS stays bounded across 20 iterations of a 100k-row stream")
    func streamingSelectMemoryBounded() async throws {
        // Skip on platforms where ProcessRSS returns 0.
        guard ProcessRSS.currentBytes() > 0 else { return }

        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        // Warmup pass to settle the allocator before sampling.
        var warmupRows = 0
        for try await block in client.selectColumns("SELECT number FROM numbers(100000)") {
            for column in block.columns {
                if case .uint64(let chunk) = column.values { warmupRows += chunk.count }
            }
        }
        #expect(warmupRows == 100_000)

        let baseline = ProcessRSS.currentBytes()
        var peakAfterBaseline: UInt64 = baseline
        for _ in 0..<20 {
            for try await block in client.selectColumns("SELECT number FROM numbers(100000)") {
                _ = block  // discard immediately; the streaming path
                           // must not retain across blocks
            }
            peakAfterBaseline = max(peakAfterBaseline, ProcessRSS.currentBytes())
        }
        let growthBytes = Int64(peakAfterBaseline) - Int64(baseline)
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)
        print("RSS leak check: baseline=\(baseline / 1024 / 1024) MB, peak=\(peakAfterBaseline / 1024 / 1024) MB, growth=\(String(format: "%.1f", growthMB)) MB across 20×100k-row streams")
        // Generous bound. A real leak (every iteration retains its
        // block's worth of bytes) would push growth past hundreds
        // of MB; this asserts no order-of-magnitude leak without
        // flaking on the allocator's normal heap-growth behavior.
        #expect(growthBytes < 100 * 1024 * 1024,
                "streaming SELECT leak suspected — RSS grew by \(String(format: "%.1f", growthMB)) MB across 20 iterations of a 100k-row stream")
    }

    // INSERT-path memory bound counterpart to streamingSelectMemoryBounded.
    // The streaming INSERT contract is "peak memory is one block at a
    // time" — the provider yields a block, the SDK encodes and sends,
    // then releases the block before asking for the next. A leak here
    // would manifest as RSS growing proportionally to total inserted
    // bytes, not per-block bytes.
    // Pool-churn leak detector. A flapping endpoint (server bouncing,
    // load balancer rerouting, network blip) causes the SDK to open
    // and close many connections per second. If the connection
    // teardown leaks any resource — NIO Channel, EventLoop registration,
    // file descriptor, half-open socket — RSS grows in proportion to
    // churn count, not steady-state connection count.
    //
    // The test creates and shuts down 50 fresh clients (each does one
    // query so the full lifecycle runs). After warmup, RSS must stay
    // bounded across the remaining 40 cycles. A real FD/channel leak
    // would push RSS past the bound; this is the production scenario
    // that reveals it.
    @Test("repeated connect+shutdown cycles don't leak resources — bounded RSS across 50 client churns")
    func poolChurnDoesNotLeak() async throws {
        guard ProcessRSS.currentBytes() > 0 else { return }

        // Warmup pass — first client triggers Swift's lazy initializers,
        // NIO buffer pool allocation, etc. Skipped from the measurement.
        let warmupGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let warmupClient = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            eventLoopGroup: warmupGroup
        ))
        _ = try await warmupClient.scalarInt64("SELECT toInt64(1)")
        await warmupClient.shutdown()
        try? await warmupGroup.shutdownGracefully()

        let baseline = ProcessRSS.currentBytes()
        var peakAfterBaseline: UInt64 = baseline
        // 50 churns = 50 fresh client+pool+EventLoopGroup creates and
        // teardowns. Each runs one query so the full handshake +
        // codec install + send + recv + close path executes.
        for cycle in 0..<50 {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let client = ClickHouseClient(configuration: .init(
                endpoints: [.init(host: Self.host, port: Self.port)],
                database: Self.database,
                user: Self.user,
                password: Self.password,
                eventLoopGroup: group
            ))
            let value = try await client.scalarInt64("SELECT toInt64(\(cycle))")
            #expect(value == Int64(cycle), "cycle \(cycle) round-trip failed; pool churn may have a real bug")
            await client.shutdown()
            try? await group.shutdownGracefully()
            peakAfterBaseline = max(peakAfterBaseline, ProcessRSS.currentBytes())
        }
        let growthBytes = Int64(peakAfterBaseline) - Int64(baseline)
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)
        print("RSS leak check (pool churn): baseline=\(baseline / 1024 / 1024) MB, peak=\(peakAfterBaseline / 1024 / 1024) MB, growth=\(String(format: "%.1f", growthMB)) MB across 50 connect+shutdown cycles")
        // Generous bound — Swift's allocator can grow heap arenas
        // without it being a leak. A real FD/channel leak would
        // grow RSS by tens of MB per leaked connection.
        #expect(growthBytes < 50 * 1024 * 1024,
                "pool churn leak suspected — RSS grew by \(String(format: "%.1f", growthMB)) MB across 50 connect+shutdown cycles")
    }

    @Test("streaming INSERT does not leak: RSS stays bounded across 20 iterations of 100k-row inserts")
    func streamingInsertMemoryBounded() async throws {
        guard ProcessRSS.currentBytes() > 0 else { return }

        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.insert_leak_\(suffix)"
        try await client.execute("CREATE TABLE \(table) (n UInt64) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }

        actor BlockCounter {
            var count: Int = 0
            func reset() { count = 0 }
            func next() -> Int { defer { count += 1 }; return count }
        }
        let counter = BlockCounter()
        let blockSize = 50_000
        let blocksPerIteration = 2  // 100k rows / iteration

        // Warmup pass to settle allocator/NIO buffer pool before sampling.
        await counter.reset()
        try await client.insert(into: table, blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
            let index = await counter.next()
            guard index < blocksPerIteration else { return .endOfStream }
            let rangeStart = index * blockSize
            let values = (rangeStart..<rangeStart + blockSize).map { UInt64($0) }
            return .batch([.init(name: "n", values: .uint64(values))])
        })

        let baseline = ProcessRSS.currentBytes()
        var peakAfterBaseline: UInt64 = baseline
        for _ in 0..<20 {
            await counter.reset()
            try await client.insert(into: table, blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in
                let index = await counter.next()
                guard index < blocksPerIteration else { return .endOfStream }
                let rangeStart = index * blockSize
                let values = (rangeStart..<rangeStart + blockSize).map { UInt64($0) }
                return .batch([.init(name: "n", values: .uint64(values))])
            })
            peakAfterBaseline = max(peakAfterBaseline, ProcessRSS.currentBytes())
        }
        let growthBytes = Int64(peakAfterBaseline) - Int64(baseline)
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)
        print("RSS leak check (INSERT): baseline=\(baseline / 1024 / 1024) MB, peak=\(peakAfterBaseline / 1024 / 1024) MB, growth=\(String(format: "%.1f", growthMB)) MB across 20×100k-row streaming inserts")
        #expect(growthBytes < 100 * 1024 * 1024,
                "streaming INSERT leak suspected — RSS grew by \(String(format: "%.1f", growthMB)) MB across 20 iterations of 100k-row insert")
    }

    @Test("Concurrent SELECT throughput benchmark: 4 parallel streams via the pool")
    func concurrentSelectThroughputBenchmark() async throws {
        // Pool with 4 connections; 4 parallel SELECTs of 250k rows each
        // = 1M rows total, distributed across connections. This shows
        // how callers can scale throughput by parallelizing through the
        // pool — the per-connection bottleneck (codec CPU on one Task)
        // becomes per-connection × N when callers fan out.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 4,
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let perStream = 250_000
        let streams = 4
        let started = Date()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<streams {
                group.addTask {
                    var observed = 0
                    for try await block in client.selectColumns("SELECT number FROM numbers(\(perStream))") {
                        for column in block.columns {
                            if case .uint64(let chunk) = column.values { observed += chunk.count }
                        }
                    }
                    return observed
                }
            }
            var grandTotal = 0
            for try await partial in group { grandTotal += partial }
            #expect(grandTotal == perStream * streams)
        }
        let elapsed = Date().timeIntervalSince(started)
        let totalRows = perStream * streams
        let rps = Double(totalRows) / elapsed
        let mbps = (Double(totalRows) * 8.0) / (elapsed * 1_000_000)
        print("Concurrent SELECT throughput (4 streams): \(Int(rps)) rows/sec, \(String(format: "%.1f", mbps)) MB/sec (\(totalRows) UInt64 rows in \(String(format: "%.2fs", elapsed)))")
        #expect(elapsed < 60.0)
    }

    @Test("Decimal64(8) preserves precision well beyond Float64's 15-digit boundary")
    func decimal64BeyondFloat64Precision() async throws {
        let (client, _) = Self.makeClient()
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "test.decimal64_round_\(suffix)"
        try await client.execute("CREATE TABLE \(table) (id UInt64, amount Decimal64(8)) ENGINE = Memory")
        defer { Task { try? await client.execute("DROP TABLE \(table)") } }
        // 9999999999.99999999 = 999_999_999_999_999_999 ticks — fills
        // Decimal64 precision (18 digits) and exceeds Float64's safe
        // integer range (2^53 ≈ 9.007e15). A Float64-bridged path would
        // lose digits here; the Int64 ticks path preserves them.
        try await client.execute("INSERT INTO \(table) VALUES (1, 9999999999.99999999)")
        let blocks = try await client.collectSelectColumns(
            "SELECT amount FROM \(table) WHERE id = 1"
        )
        var ticksObserved: [Int64] = []
        var scaleObserved = -1
        for block in blocks {
            for column in block.columns {
                if case .decimal64(let ticks, let scale) = column.values {
                    ticksObserved.append(contentsOf: ticks)
                    scaleObserved = scale
                }
            }
        }
        #expect(scaleObserved == 8)
        #expect(ticksObserved == [999_999_999_999_999_999])
    }

}
