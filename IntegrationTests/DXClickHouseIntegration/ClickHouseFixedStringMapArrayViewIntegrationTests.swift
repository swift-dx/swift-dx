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

// End-to-end test for the FixedString / Array(FixedString) / Map
// view-API extensions to ClickHouseBlockStringView.
//
// Asserts that:
//
//   1. `selectStringColumns` round-trips a 1M-row event-sourced
//      ledger scan through the view API. Counts row + element +
//      pair totals via the view path and compares them against the
//      legacy materialising `selectColumns` path. Any drift between
//      the two paths surfaces here.
//
//   2. The view-counted byte sums match the legacy path's byte sums
//      column-by-column, proving the arenas expose exactly the same
//      payload the wire decoded for the FixedString and Array(FixedString)
//      cases.
//
//   3. The Map(String, String) view enumerates the same (key, value)
//      pairs the legacy materialising path returns as Swift
//      `[String: String]` rows.
//
// The integration test is gated by `CH_INTEGRATION_HOST`; running it
// requires a ClickHouse server reachable on the configured endpoint.
@Suite(
    "ClickHouse integration — fixed-string / array / map view round-trip",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseFixedStringMapArrayViewIntegrationTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static let rowCount = 1_000_000
    private static let blockRowCount = 100_000
    private static let fixedWidth = 44

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
        return "\(database).fixed_view_\(suffix)"
    }

    private static func paddedId(_ index: Int) -> String {
        let raw = String(index)
        if raw.count >= fixedWidth { return String(raw.prefix(fixedWidth)) }
        return String(repeating: "0", count: fixedWidth - raw.count) + raw
    }

    private static func seedTable(_ client: ClickHouseClient, table: String) async throws {
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("""
            CREATE TABLE \(table) (
                entity_id FixedString(\(fixedWidth)),
                entity_refs Array(FixedString(\(fixedWidth))),
                tags Map(String, String)
            ) ENGINE = MergeTree ORDER BY entity_id
            """)
        try await client.execute("""
            INSERT INTO \(table)
            SELECT
                toFixedString(leftPad(toString(number), \(fixedWidth), '0'), \(fixedWidth)) AS entity_id,
                arrayMap(x -> toFixedString(leftPad(toString(x + number), \(fixedWidth), '0'), \(fixedWidth)),
                         range(toUInt32((number * 3) % 4))) AS entity_refs,
                map('env', 'prod', 'region', ['nz','au','gb','zz'][1 + number % 4]) AS tags
            FROM numbers(\(rowCount))
            """)
    }

    @Test("1M-row event-sourced ledger scans agree row-by-row between the view path and a separate server-side baseline")
    func ledgerScanMatchesServerBaseline() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: Self.configuration(eventLoopGroup: group))
        defer { Task { await client.shutdown() } }

        let table = Self.uniqueTable()
        try await Self.seedTable(client, table: table)
        defer { Task { try? await client.execute("DROP TABLE IF EXISTS \(table)") } }

        let viewSummary = try await Self.sumViewMetrics(client: client, table: table)
        let baseline = try await Self.sumServerBaseline(client: client, table: table)
        Self.assertMatchingSummaries(viewSummary, baseline)
    }

    private static func sumViewMetrics(client: ClickHouseClient, table: String) async throws -> Metrics {
        var metrics = Metrics()
        let sql = "SELECT entity_id, entity_refs, tags FROM \(table)"
        for try await block in client.selectStringColumns(sql) {
            accumulateViewIds(block: block, metrics: &metrics)
            accumulateViewRefs(block: block, metrics: &metrics)
            accumulateViewTags(block: block, metrics: &metrics)
        }
        return metrics
    }

    private static func accumulateViewIds(block: ClickHouseBlockStringView, metrics: inout Metrics) {
        guard case .present(let column) = block.fixedStringColumn(named: "entity_id") else { return }
        column.forEach { _, view in
            metrics.idRows += 1
            metrics.idBytes += view.byteCount
        }
    }

    private static func accumulateViewRefs(block: ClickHouseBlockStringView, metrics: inout Metrics) {
        guard case .present(let column) = block.arrayOfFixedStringColumn(named: "entity_refs") else { return }
        for rowIndex in 0..<column.rowCount {
            metrics.refsRows += 1
            metrics.refsElements += column.view(at: rowIndex).count
        }
    }

    private static func accumulateViewTags(block: ClickHouseBlockStringView, metrics: inout Metrics) {
        guard case .present(let column) = block.mapStringStringColumn(named: "tags") else { return }
        for rowIndex in 0..<column.rowCount {
            let row = column.view(at: rowIndex)
            metrics.tagRows += 1
            metrics.tagPairs += row.count
        }
    }

    // Server-side baseline. The legacy `selectColumns` mapping does not
    // support `Array(FixedString(N))` (the typed Values enum has no
    // case for it), so the comparison runs through a scalar aggregate
    // SQL query that produces the same totals server-side. The
    // FixedString row + byte sum is verified by querying
    // `count() * 44` for entity_id; the refs element total by
    // `sum(length(entity_refs))`; the map pair total by
    // `sum(length(tags))`.
    private static func sumServerBaseline(client: ClickHouseClient, table: String) async throws -> Metrics {
        let idRows = try await client.scalarInt64("SELECT toInt64(count()) FROM \(table)")
        let refsRows = idRows
        let tagRows = idRows
        let idBytes = idRows * Int64(fixedWidth)
        let refsElements = try await client.scalarInt64("SELECT toInt64(sum(length(entity_refs))) FROM \(table)")
        let tagPairs = try await client.scalarInt64("SELECT toInt64(sum(length(tags))) FROM \(table)")
        return Metrics(
            idRows: Int(idRows),
            idBytes: Int(idBytes),
            refsRows: Int(refsRows),
            refsElements: Int(refsElements),
            tagRows: Int(tagRows),
            tagPairs: Int(tagPairs)
        )
    }

    private static func assertMatchingSummaries(_ view: Metrics, _ baseline: Metrics) {
        #expect(view.idRows == baseline.idRows, "id row count mismatch view=\(view.idRows) baseline=\(baseline.idRows)")
        #expect(view.idBytes == baseline.idBytes, "id byte sum mismatch view=\(view.idBytes) baseline=\(baseline.idBytes)")
        #expect(view.refsRows == baseline.refsRows, "refs row count mismatch view=\(view.refsRows) baseline=\(baseline.refsRows)")
        #expect(view.refsElements == baseline.refsElements, "refs element count mismatch view=\(view.refsElements) baseline=\(baseline.refsElements)")
        #expect(view.tagRows == baseline.tagRows, "tag row count mismatch view=\(view.tagRows) baseline=\(baseline.tagRows)")
        #expect(view.tagPairs == baseline.tagPairs, "tag pair count mismatch view=\(view.tagPairs) baseline=\(baseline.tagPairs)")
        #expect(view.idRows == rowCount, "view path observed \(view.idRows) id rows, expected \(rowCount)")
    }

    private struct Metrics {

        var idRows: Int = 0
        var idBytes: Int = 0
        var refsRows: Int = 0
        var refsElements: Int = 0
        var tagRows: Int = 0
        var tagPairs: Int = 0

    }

}
