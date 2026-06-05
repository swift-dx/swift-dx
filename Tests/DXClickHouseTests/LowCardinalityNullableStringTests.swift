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

// LowCardinality(Nullable(String)) decodes into a nullable string column. Its
// dictionary reserves index 0 as the NULL placeholder, so a key of 0 is a NULL
// row and every other key resolves to its dictionary entry. This pins the
// decode against a hand-crafted block: dictionary ["", "a", "b"] with keys
// [1, 0, 2, 1] yields ["a", nil, "b", "a"] into a `String?` field.
@Suite("DXClickHouse LowCardinality(Nullable(String)) decodes nullable strings")
struct LowCardinalityNullableStringTests {

    struct Row: Codable, Sendable, Equatable {
        let status: String?
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func nullableBody() -> [UInt8] {
        uint64LE(1)
            + uint64LE(0x0200)
            + uint64LE(3) + [0] + [1, 97] + [1, 98]
            + uint64LE(4) + [1, 0, 2, 1]
    }

    @Test("the typed decoder reads LowCardinality(Nullable(String)) with index 0 as NULL")
    func decodesNullableLowCardinality() throws {
        let body = Self.nullableBody()
        let block = ClickHouseBlock(
            rowCount: 4, columnCount: 1,
            columnNames: ["status"],
            columnTypes: ["LowCardinality(Nullable(String))"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 4)
        #expect(rows == [Row(status: "a"), Row(status: nil), Row(status: "b"), Row(status: "a")])
    }
}
