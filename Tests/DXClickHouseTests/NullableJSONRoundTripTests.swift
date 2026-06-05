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
import Testing

// ClickHouseJSON is String-compatible, so a nullable JSON payload is a
// Nullable(String) column. A `let payload: ClickHouseJSON?` field must round
// trip: present rows carry the JSON text, absent rows are NULL. Both sides
// were broken - encode had no optional-JSON path (opaque reject) and decode
// did not accept a .nullableString column for a JSON field.
@Suite("a ClickHouseJSON? field round-trips through a Nullable(String) column")
struct NullableJSONRoundTripTests {

    private struct Row: Codable, Equatable {
        let payload: ClickHouseJSON?
    }

    @Test("present and absent JSON payloads round-trip")
    func roundTrips() throws {
        let rows = [
            Row(payload: ClickHouseJSON("{\"k\":1}")),
            Row(payload: nil),
            Row(payload: ClickHouseJSON("[1,2,3]")),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("decoding reads a directly-built Nullable(String) column as JSON")
    func decodesNullableStringColumn() throws {
        let column = ClickHouseNamedColumn(
            name: "payload",
            column: .nullableString([.present(Array("{\"a\":true}".utf8)), .absent])
        )
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 2)
        #expect(decoded[0].payload == ClickHouseJSON("{\"a\":true}"))
        #expect(decoded[1].payload == nil)
    }
}
