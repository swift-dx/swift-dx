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

// Map(String, String) - tags, labels, attributes - maps most naturally onto
// a Swift [String: String] field. That used to fail both ways: the decoder
// routed a dictionary target through a keyed container it does not
// implement, and the encoder rejected it through an unkeyed container, so
// callers were forced onto the raw-bytes ClickHouseMap escape hatch. Both
// directions now work, keyed on the static dictionary type so an empty
// dictionary keeps its declared element types.
@Suite("Map(String, String) round-trips through a Swift [String: String]")
struct NativeStringMapCodableTests {

    private struct Row: Codable, Equatable {
        let labels: [String: String]
    }

    @Test("a populated dictionary round-trips through encode then decode")
    func roundTrips() throws {
        let original = Row(labels: ["env": "prod", "az": "us-east-1", "tier": ""])
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("an empty dictionary round-trips as empty")
    func emptyRoundTrips() throws {
        let original = Row(labels: [:])
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("decoding reads a directly-built Map(String, String) column")
    func decodesBuiltColumn() throws {
        let map = ClickHouseMap.stringToString([("region", "eu"), ("shard", "3")])
        let column = ClickHouseNamedColumn(
            name: "labels",
            column: .map(keys: [map.keys], values: [map.values], keyElement: .string, valueElement: .string)
        )
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        #expect(rows[0].labels == ["region": "eu", "shard": "3"])
    }

    @Test("a String dictionary over a non-String-valued map is rejected")
    func mismatchedValueTypeThrows() {
        let column = ClickHouseNamedColumn(
            name: "labels",
            column: .map(keys: [[Array("k".utf8)]], values: [[ClickHouseArray.uint64s([1]).elements[0]]], keyElement: .string, valueElement: .uint64)
        )
        #expect(throws: (any Error).self) {
            _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: [column], rowCount: 1)
        }
    }
}
