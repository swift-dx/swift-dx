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
import Testing

// Array(Nullable(DateTime)) into [Date?]. A [Date?] field encodes as
// Array(Nullable(DateTime)) (epoch seconds), so — unlike the parameterized
// shaped wrappers — there is no element metadata to infer, and an all-nil or
// empty row is fine. Decode is element-aware (DateTime/Date/Date32/DateTime64),
// mirroring the non-nullable [Date] path.
@Suite("Array(Nullable(DateTime)) round-trips into [Date?]")
struct ArrayOfNullableDateTests {

    private struct Row: Codable, Sendable, Equatable { let v: [Date?] }

    @Test("a [Date?] batch round-trips, including empty and all-nil rows")
    func roundTrips() throws {
        let rows = [
            Row(v: [Date(timeIntervalSince1970: 1000), nil, Date(timeIntervalSince1970: 2000)]),
            Row(v: []),
            Row(v: [nil, nil]),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Array(Nullable(DateTime))")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: rows.count)
        #expect(decoded == rows)
    }

    @Test("a [Date?] element outside the DateTime epoch range is rejected")
    func outOfRangeRejected() {
        // Pre-1970 instant cannot be a UInt32 epoch-second DateTime.
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(v: [Date(timeIntervalSince1970: -1)])])
        }
    }
}
