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

import DXClickHouse
import DXCore
import Foundation
import Testing

// Drives `ClickHouseClient.stream(_:as:handler:)` and the streaming
// AsyncThrowingStream surface across realistic shapes: a long-running
// numbers() scan that delivers thousands of rows, a stream that the
// handler consumes incrementally, a stream that surfaces a typed error
// for a malformed query, and the `[UInt8]` SQL-bytes overload.
@Suite(
    "DXClickHouse OperationsCoverage: long-running streaming receive",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct StreamCoverageIT {

    struct NumberRow: Decodable, Sendable, Equatable {
        let n: UInt64
    }

    actor SumHandler: DXMessageHandler {

        typealias Message = NumberRow
        typealias Failure = ClickHouseError

        private(set) var rowsReceived: Int = 0
        private(set) var sum: UInt64 = 0
        private(set) var failures: [ClickHouseError] = []

        func receive(_ message: NumberRow) async {
            rowsReceived += 1
            sum &+= message.n
        }

        func receive(error: ClickHouseError) async {
            failures.append(error)
        }

        func snapshot() -> (rowsReceived: Int, sum: UInt64, failures: [ClickHouseError]) {
            (rowsReceived, sum, failures)
        }
    }

    @Test("select streaming delivers every row across a 100k-row numbers() scan")
    func selectStreamLargeNumbers() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        var observed: UInt64 = 0
        for try await row in client.select("SELECT toUInt64(number) AS n FROM numbers(100000)", as: NumberRow.self) {
            observed &+= row.n
        }
        // Sum of 0..99999 = 99999 * 100000 / 2 = 4_999_950_000
        #expect(observed == 4_999_950_000)
    }

    @Test("stream(handler:) delivers every row through DXMessageHandler for a 50k-row scan")
    func streamHandlerLargeNumbers() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        let handler = SumHandler()
        let task = client.stream(
            "SELECT toUInt64(number) AS n FROM numbers(50000)",
            as: NumberRow.self,
            handler: handler
        )
        await task.value
        let snapshot = await handler.snapshot()
        #expect(snapshot.rowsReceived == 50000)
        // Sum 0..49999 = 1_249_975_000
        #expect(snapshot.sum == 1_249_975_000)
        #expect(snapshot.failures.isEmpty)
    }

    @Test("stream(handler:) surfaces typed error for an invalid query")
    func streamHandlerInvalidQuerySurfacesError() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        let handler = SumHandler()
        let task = client.stream(
            "SELECT toUInt64(n) FROM table_that_does_not_exist_anywhere",
            as: NumberRow.self,
            handler: handler
        )
        await task.value
        let snapshot = await handler.snapshot()
        #expect(snapshot.rowsReceived == 0)
        #expect(snapshot.failures.count == 1)
        switch snapshot.failures[0] {
        case .queryFailed: break
        default: Issue.record("expected queryFailed, got \(snapshot.failures[0])")
        }
    }

    @Test("stream from raw SQL [UInt8] bytes overload delivers rows identically")
    func streamFromSQLBytes() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        let handler = SumHandler()
        let task = client.stream(
            Array("SELECT toUInt64(number) AS n FROM numbers(10000)".utf8),
            as: NumberRow.self,
            handler: handler
        )
        await task.value
        let snapshot = await handler.snapshot()
        #expect(snapshot.rowsReceived == 10000)
        #expect(snapshot.failures.isEmpty)
    }

    @Test("two streaming queries on the same client serialise on the worker queue")
    func streamSerialisesAcrossCalls() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        var firstSum: UInt64 = 0
        for try await row in client.select("SELECT toUInt64(number) AS n FROM numbers(1000)", as: NumberRow.self) {
            firstSum &+= row.n
        }
        var secondSum: UInt64 = 0
        for try await row in client.select("SELECT toUInt64(number) AS n FROM numbers(2000)", as: NumberRow.self) {
            secondSum &+= row.n
        }
        // sum 0..999 = 499500; sum 0..1999 = 1999000
        #expect(firstSum == 499_500)
        #expect(secondSum == 1_999_000)
    }

    @Test("stream that runs for ~2 seconds via sleepEachRow stays alive end-to-end")
    func streamLongRunningSleep() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        let started = ContinuousClock.now
        struct SleepyRow: Decodable, Sendable { let r: UInt8 }
        var observed = 0
        // Per-block sleep ceiling on the server is 3s; use 0.2s × 10 = 2s
        // total which stays well inside the server's per-block budget
        // and still gives the stream meaningful wall-clock time to
        // exercise the long-lived receive path.
        for try await _ in client.select(
            "SELECT toUInt8(sleepEachRow(0.2)) AS r FROM numbers(10)",
            as: SleepyRow.self
        ) {
            observed += 1
        }
        let elapsed = ContinuousClock.now - started
        #expect(observed == 10)
        #expect(
            elapsed >= .milliseconds(1800),
            "expected at least 1.8s of server-side sleep, got \(elapsed)"
        )
    }
}
