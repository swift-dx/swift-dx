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

// DXMessageHandler input form for the continuous stream() operation on
// ClickHouseClient. Drives both the String-SQL and the [UInt8]-SQL
// overloads of stream(...) and asserts the typed rows arrive.
@Suite(
    "ClickHouseClient DXMessageHandler overload coverage",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientMessageHandlerOverloadTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    struct PointRow: Codable, Sendable, Equatable {
        let v: UInt64
    }

    actor PointCollector: DXMessageHandler {

        typealias Message = PointRow
        typealias Failure = ClickHouseError

        private(set) var rows: [PointRow] = []
        private(set) var failures: [ClickHouseError] = []

        func receive(_ message: PointRow) async {
            rows.append(message)
        }

        func receive(error: ClickHouseError) async {
            failures.append(error)
        }

        func snapshot() -> (rows: [PointRow], failures: [ClickHouseError]) {
            (rows, failures)
        }
    }

    @Test("stream(String, handler:) delivers rows via DXMessageHandler")
    func stringStreamDeliversRows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = PointCollector()
        let task = client.stream(
            "SELECT toUInt64(number) AS v FROM numbers(5)",
            as: PointRow.self,
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.map(\.v) == [0, 1, 2, 3, 4])
        #expect(snapshot.failures.isEmpty)
    }

    @Test("stream([UInt8], handler:) delivers rows via DXMessageHandler")
    func bytesStreamDeliversRows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = PointCollector()
        let bytes = Array("SELECT toUInt64(number) AS v FROM numbers(3)".utf8)
        let task = client.stream(
            bytes,
            as: PointRow.self,
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.map(\.v) == [0, 1, 2])
        #expect(snapshot.failures.isEmpty)
    }

    @Test("stream surfaces a typed error to the handler for an invalid query")
    func streamSurfacesErrorToHandler() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = PointCollector()
        let task = client.stream(
            "SELECT * FROM definitely_not_a_real_table_xyz",
            as: PointRow.self,
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.failures.count == 1)
        switch snapshot.failures[0] {
        case .queryFailed: break
        default: Issue.record("expected queryFailed, got \(snapshot.failures[0])")
        }
    }

    @Test("stream(handler:) accepts a per-call timeout override")
    func streamTimeoutOverride() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = PointCollector()
        let task = client.stream(
            "SELECT toUInt64(number) AS v FROM numbers(2)",
            as: PointRow.self,
            timeout: .seconds(5),
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.count == 2)
    }
}
