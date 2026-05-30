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

// End-to-end test for the wire-buffer-survival String view path.
// Asserts that:
//
//   1. `selectStringColumns` round-trips 1M rows of String payloads
//      from a real ClickHouse instance back through the new
//      `ClickHouseBlockStringView` projection without losing any
//      bytes.
//
//   2. The view-counted byte sum matches the byte sum produced by
//      the legacy materialising `selectColumns` path, proving the
//      arena exposes exactly the same payload the wire decoded.
//
//   3. Per-row `asString()` materialisation on a sampled subset of
//      rows reproduces the expected canonical payload string.
//
// The integration test is gated by `CH_INTEGRATION_HOST`; running it
// requires a ClickHouse server reachable on the configured endpoint.
@Suite(
    "ClickHouse integration — string view round-trip",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseStringViewIntegrationTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static let rowCount = 1_000_000
    private static let blockRowCount = 100_000

    private static func configuration(eventLoopGroup: EventLoopGroup) -> ClickHouseClient.Configuration {
        .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            maxConnections: 2,
            maxIdleConnections: 2,
            eventLoopGroup: eventLoopGroup
        )
    }

    private static func uniqueTable() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").prefix(12)
        return "\(database).string_view_\(suffix)"
    }

    private static func seedTable(_ client: ClickHouseClient, table: String) async throws {
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt64, payload String) ENGINE = MergeTree ORDER BY id")
        let totalBlocks = (rowCount + blockRowCount - 1) / blockRowCount
        for blockIndex in 0..<totalBlocks {
            let blockStart = blockIndex * blockRowCount
            let blockEnd = min(blockStart + blockRowCount, rowCount)
            let ids = (blockStart..<blockEnd).map { UInt64($0) }
            let payloads = (blockStart..<blockEnd).map { "payload-\($0)" }
            try await client.insert(into: table, columns: [
                .init(name: "id", values: .uint64(ids)),
                .init(name: "payload", values: .string(payloads)),
            ])
        }
    }

    private static func sumViewBytes(client: ClickHouseClient, table: String) async throws -> Int {
        var totalRows = 0
        var totalBytes = 0
        for try await block in client.selectStringColumns("SELECT payload FROM \(table)") {
            switch block.stringColumn(named: "payload") {
            case .present(let column):
                totalRows += column.rowCount
                column.forEach { _, view in
                    totalBytes += view.utf8Length
                }
            case .absent:
                Issue.record("payload column missing from string view block")
            }
        }
        #expect(totalRows == rowCount, "view path observed \(totalRows) rows, expected \(rowCount)")
        return totalBytes
    }

    private static func sumLegacyBytes(client: ClickHouseClient, table: String) async throws -> Int {
        var totalRows = 0
        var totalBytes = 0
        for try await block in client.selectColumns("SELECT payload FROM \(table)") {
            for column in block.columns where column.name == "payload" {
                if case .string(let strings) = column.values {
                    totalRows += strings.count
                    for string in strings {
                        totalBytes += string.utf8.count
                    }
                }
            }
        }
        #expect(totalRows == rowCount, "legacy path observed \(totalRows) rows, expected \(rowCount)")
        return totalBytes
    }

    @Test("selectStringColumns round-trips 1M rows with byte counts that match the legacy materializing path")
    func stringViewRoundTripMatchesLegacyByteCount() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let table = Self.uniqueTable()
        try await Self.seedTable(client, table: table)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        let viewBytes = try await Self.sumViewBytes(client: client, table: table)
        let legacyBytes = try await Self.sumLegacyBytes(client: client, table: table)
        #expect(
            viewBytes == legacyBytes,
            "view byte sum \(viewBytes) must equal legacy byte sum \(legacyBytes) — proves the arena exposes the same payload the wire decoded"
        )
        #expect(viewBytes > 0, "1M payloads must produce a positive byte sum")
    }

    @Test("a sampled subset of rows materialises through asString() to the canonical payload-N text")
    func stringViewMaterialisationMatchesCanonicalPayload() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let table = Self.uniqueTable()
        try await Self.seedTable(client, table: table)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        var observedRowOffset = 0
        var samplesChecked = 0
        for try await block in client.selectStringColumns("SELECT payload FROM \(table) ORDER BY id") {
            let column = try block.requireStringColumn(named: "payload")
            try Self.checkSampledRows(
                column: column,
                rowOffset: observedRowOffset,
                samplesChecked: &samplesChecked
            )
            observedRowOffset += column.rowCount
        }
        #expect(samplesChecked > 0, "the sampling loop must inspect at least one row")
    }

    private static func checkSampledRows(
        column: ClickHouseStringColumnView,
        rowOffset: Int,
        samplesChecked: inout Int
    ) throws {
        let blockRows = column.rowCount
        if blockRows == 0 { return }
        let stride = max(1, blockRows / 8)
        var localOffset = 0
        while localOffset < blockRows {
            let globalRowIndex = rowOffset + localOffset
            let expected = "payload-\(globalRowIndex)"
            let view = column.view(at: localOffset)
            #expect(view == expected, "row \(globalRowIndex) view bytes mismatched expected payload")
            #expect(view.asString() == expected, "row \(globalRowIndex) materialised string mismatched expected payload")
            samplesChecked += 1
            localOffset += stride
        }
    }

}
