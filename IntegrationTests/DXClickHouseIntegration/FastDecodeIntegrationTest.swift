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
import Foundation
import Testing

// The columnar fast path (selectAllFast / ClickHouseRowDecodable) must return
// exactly what the Codable selectAll returns, across block boundaries, for a
// real server result. It only adds speed, never changes values.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct FastDecodeIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct CodableRow: Codable, Sendable, Equatable { let id: UInt64; let name: String; let value: Double }
    private struct FastRow: ClickHouseRowDecodable, ClickHouseColumnarEncodable, Sendable, Equatable {
        let id: UInt64; let name: String; let value: Double
        static let clickHouseColumnNames = ["id", "name", "value"]
        init(id: UInt64, name: String, value: Double) { self.id = id; self.name = name; self.value = value }
        static func decodeBlock(_ block: ClickHouseColumnBlock) throws(ClickHouseError) -> [FastRow] {
            let ids = try block.uint64(0); let names = try block.strings(1); let values = try block.double(2)
            return (0..<block.count).map { FastRow(id: ids[$0], name: names[$0], value: values[$0]) }
        }
        static func encodeColumnar(_ rows: [FastRow], into sink: inout ClickHouseColumnSink) {
            var ids = [UInt64](); var names = [String](); var values = [Double]()
            for row in rows { ids.append(row.id); names.append(row.name); values.append(row.value) }
            sink.uint64("id", ids); sink.string("name", names); sink.double("value", values)
        }
    }

    @Test("insertFast writes rows that read back identically", .timeLimit(.minutes(1)))
    func insertFastRoundTrips() async throws {
        let client = try await Self.makeClient()
        let table = "dx_insfast_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (id UInt64, name String, value Float64) ENGINE = Memory")
        let rows = (0..<5000).map { FastRow(id: UInt64($0), name: "row_\($0 % 100)", value: Double($0) * 1.5) }
        _ = try await client.insertFast(into: table, rows: rows)
        let back = try await client.selectAllFast("SELECT id, name, value FROM \(table) ORDER BY id", as: FastRow.self)
        #expect(back == rows)
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("selectAllFast returns the same rows as Codable selectAll across blocks", .timeLimit(.minutes(2)))
    func fastMatchesCodable() async throws {
        let client = try await Self.makeClient()
        // ~3 blocks worth of rows to cross block boundaries.
        let sql = "SELECT number AS id, toString(number % 1000) AS name, number * 1.5 AS value FROM system.numbers LIMIT 200000"
        let codable = try await client.selectAll(sql, as: CodableRow.self)
        let fast = try await client.selectAllFast(sql, as: FastRow.self)
        #expect(codable.count == 200000)
        #expect(fast.count == codable.count)
        // Compare endpoints and a spot in the middle (crosses block boundaries).
        for index in [0, 1, 123456, 199998, 199999] {
            #expect(fast[index].id == codable[index].id)
            #expect(fast[index].name == codable[index].name)
            #expect(fast[index].value == codable[index].value)
        }
        var fastChecksum: UInt64 = 0, codableChecksum: UInt64 = 0
        for row in fast { fastChecksum &+= row.id }
        for row in codable { codableChecksum &+= row.id }
        #expect(fastChecksum == codableChecksum)
        await client.close()
    }

    private struct FusedRow: ClickHouseFusedDecodable, Sendable, Equatable {
        let id: UInt64; let name: String; let value: Double
        static let clickHouseColumnNames = ["id", "name", "value"]
        static func decodeFused(_ block: ClickHouseRawBlock) throws(ClickHouseError) -> [FusedRow] {
            (0..<block.count).map { FusedRow(id: block.uint64(0, $0), name: block.string(1, $0), value: block.double(2, $0)) }
        }
    }

    @Test("selectAllFused decodes a block that contains an intervening fixed-width column it does not request", .timeLimit(.minutes(1)))
    func fusedSkipsUnrequestedFixedColumn() async throws {
        let client = try await Self.makeClient()
        // 'ts' (DateTime) and 'u' (UUID) sit between the requested columns; the
        // fused parser must size them to find the offsets of id/name/value.
        let sql = """
            SELECT number AS id,
                   toDateTime(number % 100) AS ts,
                   generateUUIDv4() AS u,
                   toString(number % 10) AS name,
                   number * 1.5 AS value
            FROM numbers(1000)
            """
        let rows = try await client.selectAllFused(sql, as: FusedRow.self)
        #expect(rows.count == 1000)
        #expect(rows[0].id == 0)
        #expect(rows[0].name == "0")
        #expect(rows[0].value == 0.0)
        #expect(rows[999].id == 999)
        #expect(rows[999].name == "9")
        #expect(rows[999].value == 999 * 1.5)
        await client.close()
    }

    @Test("selectAllFast surfaces a missing column as a typed error", .timeLimit(.minutes(1)))
    func missingColumnThrows() async throws {
        let client = try await Self.makeClient()
        var threw = false
        do {
            _ = try await client.selectAllFast("SELECT number AS id, toString(number) AS other FROM system.numbers LIMIT 5", as: FastRow.self)
        } catch { threw = true }
        #expect(threw)
        // Connection stays usable after the bind failure.
        let ok = try await client.selectAllFast("SELECT number AS id, toString(number % 10) AS name, number * 1.0 AS value FROM system.numbers LIMIT 3", as: FastRow.self)
        #expect(ok.count == 3)
        await client.close()
    }
}
