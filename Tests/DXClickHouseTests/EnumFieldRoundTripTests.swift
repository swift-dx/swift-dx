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

// A Swift enum field must round-trip: the encoder writes the enum's
// RawValue into the underlying column (Int32 for an Int32-backed enum,
// String for a String-backed one) and the decoder reads it back. Before
// this, the encoder rejected the enum as an unsupported Swift type and the
// decoder rejected it as an unsupported decode target.
@Suite("Swift enum fields round-trip through encode and decode")
struct EnumFieldRoundTripTests {

    private enum Status: Int32, Codable, Equatable { case active = 1, closed = 2, pending = 7 }
    private enum Color: String, Codable, Equatable { case red, green, blue }

    private struct Row: Codable, Equatable {
        let status: Status
        let color: Color
    }

    @Test("an Int32 enum encodes to an Int32 column and a String enum to a String column")
    func encodesToUnderlyingColumns() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(status: .active, color: .red),
            Row(status: .pending, color: .blue),
        ])
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0.column.typeName) })
        #expect(byName["status"] == "Int32")
        #expect(byName["color"] == "String")
    }

    @Test("enum fields survive an encode -> decode round trip")
    func roundTrips() throws {
        let rows = [
            Row(status: .closed, color: .green),
            Row(status: .active, color: .red),
            Row(status: .pending, color: .blue),
        ]
        // The encoder produces the same typed-column representation the
        // decoder consumes, so decoding the encoded columns exercises both
        // the enum encode path and the enum decode path end to end. Packet
        // byte framing is covered separately by the block-writer tests.
        let columns = try ClickHouseRowEncoder().encode(rows)
        let result = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: rows.count)
        #expect(result == rows)
    }
}
