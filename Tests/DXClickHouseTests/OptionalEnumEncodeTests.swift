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

// An Optional Swift enum field (a nullable status / category column) must
// encode as a Nullable column and round-trip. Before this, the encoder
// rejected a present optional enum (registering a non-Nullable column) and
// threw on a nil one, so a nullable enum column could be read but not
// written — an asymmetry with the decode side.
@Suite("Optional Swift enum fields encode as Nullable and round-trip")
struct OptionalEnumEncodeTests {

    private enum Status: Int32, Codable, Equatable { case active = 1, closed = 2, pending = 7 }

    private struct Row: Codable, Equatable {
        let status: Status?
    }

    @Test("a present-first optional enum registers a Nullable column")
    func registersNullableColumn() throws {
        let columns = try ClickHouseRowEncoder().encode([
            Row(status: .active),
            Row(status: nil),
            Row(status: .closed),
        ])
        #expect(columns[0].column.typeName == "Nullable(Int32)")
        #expect(columns[0].column.rowCount == 3)
    }

    @Test("an optional enum batch round-trips present and nil")
    func roundTrips() throws {
        let rows = [
            Row(status: .pending),
            Row(status: nil),
            Row(status: .active),
            Row(status: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        let result = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: rows.count)
        #expect(result == rows)
    }

    @Test("a leading-nil optional enum defers and backfills the Nullable column")
    func leadingNilRoundTrips() throws {
        let rows = [Row(status: nil), Row(status: .active), Row(status: nil)]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Nullable(Int32)")
        #expect(columns[0].column.rowCount == 3)
        let result = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: rows.count)
        #expect(result == rows)
    }

    @Test("an optional enum that is nil on every row is rejected with a clear error")
    func allNilRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(status: nil), Row(status: nil)])
        }
    }
}
