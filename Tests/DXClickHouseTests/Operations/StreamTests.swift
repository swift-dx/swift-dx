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

@Suite(
    "ClickHouseClient stream(handler:) happy paths via DXMessageHandler",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientStreamTests {

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

    struct IDRow: Codable, Sendable, Equatable {
        let v: UInt64
    }

    actor RowCollector: DXMessageHandler {

        typealias Message = IDRow
        typealias Failure = ClickHouseError

        private(set) var rows: [IDRow] = []
        private(set) var failures: [ClickHouseError] = []

        func receive(_ message: IDRow) async {
            rows.append(message)
        }

        func receive(error: ClickHouseError) async {
            failures.append(error)
        }

        func snapshot() -> (rows: [IDRow], failures: [ClickHouseError]) {
            (rows, failures)
        }
    }

    @Test("stream(String, handler:) delivers rows in order via DXMessageHandler")
    func streamDeliversRowsOrdered() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = RowCollector()
        let task = client.stream(
            "SELECT toUInt64(number) AS v FROM numbers(5)",
            as: IDRow.self,
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.map(\.v) == [0, 1, 2, 3, 4])
        #expect(snapshot.failures.isEmpty)
    }

    @Test("stream(String, handler:) delivers zero rows for an empty result")
    func streamDeliversEmptyResult() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = RowCollector()
        let task = client.stream(
            "SELECT toUInt64(number) AS v FROM numbers(0)",
            as: IDRow.self,
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.failures.isEmpty)
    }

    @Test("stream([UInt8], handler:) accepts raw SQL bytes")
    func streamBytesOverload() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = RowCollector()
        let task = client.stream(
            Array("SELECT toUInt64(number) AS v FROM numbers(3)".utf8),
            as: IDRow.self,
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.map(\.v) == [0, 1, 2])
    }

    @Test("stream accepts a per-call timeout override")
    func streamWithTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let collector = RowCollector()
        let task = client.stream(
            "SELECT toUInt64(number) AS v FROM numbers(4)",
            as: IDRow.self,
            timeout: .seconds(5),
            handler: collector
        )
        await task.value
        let snapshot = await collector.snapshot()
        #expect(snapshot.rows.count == 4)
    }
}
