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

// Array(DateTime) decodes natively into [Date], but the encode side had
// native array support only for the basic scalar element types, so inserting
// a [Date] field failed with an opaque "nested container" error. A scalar
// Date field already encodes to DateTime (epoch seconds), so a [Date] array
// encodes to Array(DateTime) consistently — no element metadata to infer, so
// even an empty array is unambiguous. Each instant is range-checked exactly
// as the scalar path does.
@Suite("[Date] arrays insert symmetrically with how they select")
struct DateArrayEncodeTests {

    private struct Row: Codable, Sendable, Equatable {
        let stamps: [Date]
    }

    @Test("a [Date] field round-trips through encode then decode")
    func roundTrips() throws {
        let original = [Row(stamps: [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_001),
        ])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(DateTime)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [Date] encodes as an empty Array(DateTime)")
    func emptyArrayEncodes() throws {
        let original = [Row(stamps: [])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(DateTime)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("a pre-epoch instant is rejected, as in the scalar DateTime path")
    func outOfRangeRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(stamps: [Date(timeIntervalSince1970: -1)])])
        }
    }
}
