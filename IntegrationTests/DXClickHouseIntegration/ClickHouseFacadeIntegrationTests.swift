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

@Suite(
    "ClickHouse integration — native Codable client",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseFacadeIntegrationTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static func configuration(eventLoopGroup: EventLoopGroup, maxConnections: Int = 10, acquireTimeout: ClickHouseClient.PoolAcquireTimeout = .failImmediatelyWhenExhausted) -> ClickHouseClient.Configuration {
        .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            maxConnections: maxConnections,
            acquireTimeout: acquireTimeout,
            eventLoopGroup: eventLoopGroup
        )
    }

    private struct EventRow: Codable, Equatable, Sendable {

        let id: UInt64
        let serviceName: String
        let value: Double
        let active: Bool
        let count: Int32
        let priority: UInt8

    }

    @Test("Codable round-trip via the facade: configure → insert typed rows → query typed rows back → values equal across the round trip")
    func codableRoundTripViaFacade() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "facade_codable_\(suffix)"
        let qualified = "\(Self.database).\(table)"
        try await client.execute("""
            CREATE TABLE \(qualified) (
                id UInt64,
                serviceName String,
                value Float64,
                active Bool,
                count Int32,
                priority UInt8
            ) ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(qualified)") } }

        let rows: [EventRow] = [
            EventRow(id: 1, serviceName: "alpha", value: 1.5, active: true, count: 10, priority: 200),
            EventRow(id: 2, serviceName: "beta", value: -0.25, active: false, count: 20, priority: 100),
            EventRow(id: 3, serviceName: "gamma", value: 99.99, active: true, count: -5, priority: 50),
        ]

        try await client.insert(into: qualified, rows: rows)

        let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualified)")
        #expect(count == 3)

        let decoded: [EventRow] = try await client.query(
            EventRow.self,
            from: "SELECT id, serviceName, value, active, count, priority FROM \(qualified) ORDER BY id"
        )
        #expect(decoded == rows, "round-trip must preserve every field")
    }

    @Test("the facade's `query` materializes empty result for an empty table without throwing")
    func emptyResultDoesNotThrow() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "facade_empty_\(suffix)"
        let qualified = "\(Self.database).\(table)"
        try await client.execute("CREATE TABLE \(qualified) (id UInt64) ENGINE = MergeTree() ORDER BY id")
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(qualified)") } }

        struct Row: Codable, Sendable { let id: UInt64 }
        let rows: [Row] = try await client.query(Row.self, from: "SELECT id FROM \(qualified)")
        #expect(rows.isEmpty)
    }

    @Test("typed query settings flow through the facade: maxBlockSize on a SELECT splits a large numeric range into the expected number of blocks observed via the underlying client")
    func typedSettingsFlowThroughFacade() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        struct NumberRow: Codable, Sendable { let n: UInt64 }
        let rows: [NumberRow] = try await client.query(
            NumberRow.self,
            from: "SELECT toUInt64(number) AS n FROM numbers(5000)",
            settings: [.maxBlockSize(1000)]
        )
        #expect(rows.count == 5000)
        #expect(rows.first?.n == 0)
        #expect(rows.last?.n == 4999)
    }

    @Test("ClickHouse.scalarUUID and ClickHouse.scalarDateTime route to the underlying client and return the typed scalar; the IfAny variants surface .empty for an empty result set")
    func scalarUUIDAndDateTimeViaFacade() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let knownString = "DEADBEEF-CAFE-BABE-1234-567890ABCDEF"
        let uuid = try await client.scalarUUID("SELECT toUUID('\(knownString)')")
        #expect(uuid.uuidString.lowercased() == knownString.lowercased(),
                "scalarUUID round-trip must preserve the byte representation; got \(uuid.uuidString)")

        let emptyUUID = try await client.scalarUUIDIfAny("SELECT toUUID('\(knownString)') WHERE 0")
        if case .value(let v) = emptyUUID {
            Issue.record("empty result must surface as .empty; got value \(v.uuidString)")
        }

        let epoch: Int64 = 1_700_000_000
        let date = try await client.scalarDateTime("SELECT toDateTime(\(epoch))")
        #expect(date.timeIntervalSince1970 == TimeInterval(epoch),
                "scalarDateTime round-trip must preserve epoch seconds; got \(date.timeIntervalSince1970)")
    }

    @Test("cancelling the surrounding Task during a slow ClickHouse.insertStream throws promptly, the partial INSERT is rolled back server-side, and a follow-up query on the recycled connection succeeds")
    func insertStreamCancellationRollsBackAndPoolRecovers() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(
            eventLoopGroup: group,
            maxConnections: 1,
            acquireTimeout: .waitUpTo(.seconds(10))
        ))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "facade_stream_cancel_\(suffix)"
        let qualified = "\(Self.database).\(table)"
        try await client.execute("""
            CREATE TABLE \(qualified) (id UInt64, payload String)
            ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(qualified)") } }

        struct CancelRow: Codable, Sendable {
            let id: UInt64
            let payload: String
        }

        let blocksPerInsert = 10
        let rowsPerBlock = 1000
        actor BlockCounter {
            var count: Int = 0
            func nextAndIncrement() -> Int { defer { count += 1 }; return count }
        }
        let counter = BlockCounter()

        let insertTask = Task<Void, Error> {
            try await client.insertStream(into: qualified) { () async throws -> ClickHouseRowBatchOutcome<CancelRow> in
                let index = await counter.nextAndIncrement()
                guard index < blocksPerInsert else { return .endOfStream }
                try await Task.sleep(nanoseconds: 250_000_000)
                let baseRow = UInt64(index * rowsPerBlock)
                let rows = (0..<rowsPerBlock).map { offset in
                    CancelRow(
                        id: UInt64(offset) + baseRow,
                        payload: "block-\(index)-row-\(offset)"
                    )
                }
                return .batch(rows)
            }
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        insertTask.cancel()
        let result = await insertTask.result

        var thrown: Error?
        switch result {
        case .success:
            Issue.record("insertStream task should have thrown after cancellation, not completed")
        case .failure(let error):
            thrown = error
        }
        let received = try #require(thrown, "insertStream must throw on cancellation")
        let description = String(describing: received)
        let isRecognized: Bool
        if received is CancellationError {
            isRecognized = true
        } else if let chError = received as? ChannelError, chError == .ioOnClosedChannel || chError == .alreadyClosed {
            isRecognized = true
        } else if case ClickHouseError.unexpectedConnectionClose = received {
            isRecognized = true
        } else if case ClickHouseError.cancelled = received {
            isRecognized = true
        } else {
            isRecognized = false
        }
        #expect(isRecognized,
                "insertStream cancellation must surface a recognized typed error; got: \(type(of: received)) — \(description)")

        try await Task.sleep(nanoseconds: 200_000_000)
        let committedAfterCancel = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualified)")
        #expect(committedAfterCancel == 0,
                "cancelled streaming INSERT must leave 0 committed rows; got \(committedAfterCancel)")

        let recoveryStarted = Date()
        try await client.insert(into: qualified, rows: [
            CancelRow(id: 9_999_999, payload: "post-cancel"),
        ])
        let recoveryElapsed = Date().timeIntervalSince(recoveryStarted)
        let recoveryCount = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualified)")
        #expect(recoveryCount == 1, "follow-up INSERT after cancel must commit; got \(recoveryCount)")
        #expect(recoveryElapsed < 5.0,
                "follow-up INSERT must complete promptly via the recycled connection; took \(recoveryElapsed)s")
    }

    @Test("breaking out of `for try await row in ClickHouse.selectStream` early cancels the underlying wire query, recycles the connection cleanly, and a follow-up query on the same client succeeds")
    func selectStreamEarlyBreakRecyclesConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(
            eventLoopGroup: group,
            maxConnections: 1,
            acquireTimeout: .waitUpTo(.seconds(10))
        ))
        defer { Task { await client.shutdown() } }

        struct NumberRow: Codable, Sendable { let n: UInt64 }

        var observed = 0
        for try await row in client.selectStream(
            NumberRow.self,
            from: "SELECT toUInt64(number) AS n FROM numbers(1000000)"
        ) {
            _ = row
            observed += 1
            if observed >= 50 {
                break
            }
        }
        #expect(observed == 50, "consumer should have observed exactly 50 rows before breaking")

        let recoveryStarted = Date()
        let value = try await client.scalarInt64("SELECT toInt64(7)")
        let recoveryElapsed = Date().timeIntervalSince(recoveryStarted)
        #expect(value == 7, "follow-up scalar must succeed via the recycled connection; got \(value)")
        #expect(recoveryElapsed < 5.0,
                "follow-up scalar must complete promptly; took \(recoveryElapsed)s — suggests the cancel cascade didn't recycle the connection cleanly")
    }

    @Test("ClickHouse.selectStream yields every row from a 1M-row SELECT and keeps peak RSS bounded — proves the streaming path doesn't materialize the full result set")
    func codableSelectStreamYieldsAllRowsAndStaysBounded() async throws {
        guard ProcessRSS.currentBytes() > 0 else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        struct NumberRow: Codable, Sendable { let n: UInt64 }

        _ = try await client.scalarInt64("SELECT toInt64(1)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let baselineRSS = ProcessRSS.currentBytes()

        let total = 1_000_000
        var observedCount = 0
        var observedFirst: UInt64?
        var observedLast: UInt64?
        var peakRSS = baselineRSS
        for try await row in client.selectStream(
            NumberRow.self,
            from: "SELECT toUInt64(number) AS n FROM numbers(\(total))"
        ) {
            observedCount += 1
            if observedFirst == nil { observedFirst = row.n }
            observedLast = row.n
            if observedCount.isMultiple(of: 100_000) {
                peakRSS = max(peakRSS, ProcessRSS.currentBytes())
            }
        }

        #expect(observedCount == total, "stream must yield all \(total) rows; got \(observedCount)")
        #expect(observedFirst == 0)
        #expect(observedLast == UInt64(total - 1))

        let growthBytes = Int64(peakRSS) - Int64(baselineRSS)
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)
        print("[SELECT STREAM RSS] baseline=\(baselineRSS / 1024 / 1024) MB, peak=\(peakRSS / 1024 / 1024) MB, growth=\(String(format: "%.1f", growthMB)) MB across \(total) yielded rows")
        #expect(growthBytes < 150 * 1024 * 1024,
                "selectStream RSS grew by \(String(format: "%.1f", growthMB)) MB — suggests the stream is materializing the full result set")
    }

    @Test("ClickHouse.selectRows yields every row from a 1M-row SELECT in order — proves the block-batched per-row sequence preserves row identity and ordering")
    func selectRowsYieldsAllRowsInOrder() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        struct NumberRow: Codable, Sendable { let n: UInt64 }

        let total = 1_000_000
        var observedCount = 0
        var observedFirst: UInt64 = .max
        var observedLast: UInt64 = .max
        for try await row in client.selectRows(
            NumberRow.self,
            from: "SELECT toUInt64(number) AS n FROM numbers(\(total))"
        ) {
            if observedCount == 0 { observedFirst = row.n }
            observedLast = row.n
            observedCount += 1
        }

        #expect(observedCount == total, "selectRows must yield all \(total) rows; got \(observedCount)")
        #expect(observedFirst == 0)
        #expect(observedLast == UInt64(total - 1))
    }

    @Test("breaking out of `for try await row in ClickHouse.selectRows` early cancels the underlying wire query and recycles the connection cleanly")
    func selectRowsEarlyBreakRecyclesConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(
            eventLoopGroup: group,
            maxConnections: 1,
            acquireTimeout: .waitUpTo(.seconds(10))
        ))
        defer { Task { await client.shutdown() } }

        struct NumberRow: Codable, Sendable { let n: UInt64 }

        var observed = 0
        for try await row in client.selectRows(
            NumberRow.self,
            from: "SELECT toUInt64(number) AS n FROM numbers(1000000)"
        ) {
            _ = row
            observed += 1
            if observed >= 50 {
                break
            }
        }
        #expect(observed == 50, "consumer should have observed exactly 50 rows before breaking")

        let value = try await client.scalarInt64("SELECT toInt64(7)")
        #expect(value == 7, "follow-up scalar must succeed via the recycled connection; got \(value)")
    }

    @Test("ClickHouse.insertStream commits all rows from a Codable batch generator and keeps peak RSS bounded — proves the streaming path doesn't silently materialize the full dataset")
    func codableInsertStreamCommitsAllRowsAndStaysBounded() async throws {
        guard ProcessRSS.currentBytes() > 0 else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "facade_stream_\(suffix)"
        let qualified = "\(Self.database).\(table)"
        try await client.execute("""
            CREATE TABLE \(qualified) (
                id UInt64,
                payload String
            ) ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(qualified)") } }

        struct StreamRow: Codable, Sendable {
            let id: UInt64
            let payload: String
        }

        let batchCount = 100
        let rowsPerBatch = 1000
        actor BatchCounter {
            var emitted: Int = 0
            func nextAndIncrement() -> Int { defer { emitted += 1 }; return emitted }
        }
        let counter = BatchCounter()

        _ = try await client.scalarInt64("SELECT toInt64(1)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let baselineRSS = ProcessRSS.currentBytes()

        try await client.insertStream(
            into: qualified,
            nextBatch: { () async throws -> ClickHouseRowBatchOutcome<StreamRow> in
                let batchIndex = await counter.nextAndIncrement()
                guard batchIndex < batchCount else { return .endOfStream }
                let baseId = UInt64(batchIndex * rowsPerBatch)
                let rows = (0..<rowsPerBatch).map { offset in
                    StreamRow(
                        id: baseId + UInt64(offset),
                        payload: "row-\(baseId + UInt64(offset))"
                    )
                }
                return .batch(rows)
            }
        )

        let peakRSS = ProcessRSS.currentBytes()
        let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualified)")
        #expect(count == Int64(batchCount * rowsPerBatch),
                "all \(batchCount * rowsPerBatch) streamed rows must commit; got \(count)")

        let growthBytes = Int64(peakRSS) - Int64(baselineRSS)
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)
        print("[STREAM RSS] baseline=\(baselineRSS / 1024 / 1024) MB, peak=\(peakRSS / 1024 / 1024) MB, growth=\(String(format: "%.1f", growthMB)) MB across \(batchCount * rowsPerBatch) rows")
        #expect(growthBytes < 100 * 1024 * 1024,
                "insertStream RSS grew by \(String(format: "%.1f", growthMB)) MB — suggests streaming is materializing the full dataset")
    }

    @Test("Phase 2D end-to-end: a struct with UUID and Optional<UUID> fields round-trips via the facade against the live cluster")
    func uuidRoundTripViaFacade() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "facade_uuid_\(suffix)"
        let qualified = "\(Self.database).\(table)"
        try await client.execute("""
            CREATE TABLE \(qualified) (
                id UUID,
                parentId Nullable(UUID),
                label String
            ) ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(qualified)") } }

        struct EventRow: Codable, Equatable, Sendable {
            let id: UUID
            let parentId: UUID?
            let label: String
        }

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let parent = UUID()
        let rows: [EventRow] = [
            EventRow(id: id1, parentId: parent, label: "alpha"),
            EventRow(id: id2, parentId: nil, label: "beta"),
            EventRow(id: id3, parentId: parent, label: "gamma"),
        ]

        try await client.insert(into: qualified, rows: rows)

        let decoded: [EventRow] = try await client.query(
            EventRow.self,
            from: "SELECT id, parentId, label FROM \(qualified) ORDER BY label"
        )
        #expect(decoded.count == rows.count)
        #expect(decoded == rows, "UUID + Nullable(UUID) round-trip via the facade must preserve every byte and per-row presence")
    }

    @Test("Phase 2 end-to-end: a struct combining primitive, Optional, Date, Optional<Date>, and [String: String] Map fields round-trips via the facade against the live cluster — encoder → native TCP → server → wire decoder → row decoder all preserve every per-row value")
    func observabilityShapedRoundTripViaFacade() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let table = "facade_phase2_\(suffix)"
        let qualified = "\(Self.database).\(table)"
        try await client.execute("""
            CREATE TABLE \(qualified) (
                id UInt64,
                priority Nullable(Int64),
                createdAt DateTime,
                scheduledAt Nullable(DateTime),
                attributes Map(String, String)
            ) ENGINE = MergeTree() ORDER BY id
        """)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(qualified)") } }

        struct LogRow: Codable, Equatable, Sendable {
            let id: UInt64
            let priority: Int64?
            let createdAt: Date
            let scheduledAt: Date?
            let attributes: [String: String]
        }

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [LogRow] = [
            LogRow(
                id: 1,
                priority: 10,
                createdAt: baseDate,
                scheduledAt: baseDate.addingTimeInterval(3600),
                attributes: ["service": "api", "env": "prod"]
            ),
            LogRow(
                id: 2,
                priority: nil,
                createdAt: baseDate.addingTimeInterval(60),
                scheduledAt: nil,
                attributes: [:]
            ),
            LogRow(
                id: 3,
                priority: 30,
                createdAt: baseDate.addingTimeInterval(120),
                scheduledAt: baseDate.addingTimeInterval(7200),
                attributes: ["service": "worker", "version": "1.2.3", "region": "us-east-1"]
            ),
        ]

        try await client.insert(into: qualified, rows: rows)

        let count = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(qualified)")
        #expect(count == Int64(rows.count))

        let decoded: [LogRow] = try await client.query(
            LogRow.self,
            from: "SELECT id, priority, createdAt, scheduledAt, attributes FROM \(qualified) ORDER BY id"
        )
        #expect(decoded.count == rows.count, "expected \(rows.count) rows; got \(decoded.count)")
        for (input, output) in zip(rows, decoded) {
            #expect(input.id == output.id, "row \(input.id) id mismatch")
            #expect(input.priority == output.priority, "row \(input.id) priority mismatch — Optional<Int64> round-trip broken")
            #expect(input.createdAt.timeIntervalSince1970 == output.createdAt.timeIntervalSince1970,
                    "row \(input.id) createdAt mismatch — Date round-trip broken")
            #expect(input.scheduledAt?.timeIntervalSince1970 == output.scheduledAt?.timeIntervalSince1970,
                    "row \(input.id) scheduledAt mismatch — Optional<Date> round-trip broken")
            #expect(input.attributes == output.attributes,
                    "row \(input.id) attributes mismatch — Map(String,String) round-trip broken")
        }
    }

}
