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

// Symmetric to native-array decoding: a struct field that is a native Swift
// array ([String], [Int64], [Double], [Bool], ...) must INSERT into an
// Array(T) column. The encoder used to reject it - a native array fell
// through to an unkeyed container that throws - so a row that could be read
// back could not be written. Each supported element type now encodes, and
// an encode->decode round trip reproduces the original values.
@Suite("a native Swift array encodes into an Array column")
struct NativeArrayEncodeTests {

    private struct Row: Codable, Equatable {
        let tags: [String]
        let counts: [Int64]
        let codes: [UInt32]
        let ratios: [Double]
        let flags: [Bool]
        let small: [Int8]
    }

    @Test("each supported element type round-trips through encode then decode")
    func roundTripsEachElementType() throws {
        let original = Row(
            tags: ["alpha", "", "gamma"],
            counts: [-5, 0, 9_000_000_000],
            codes: [1, 2, 4_000_000_000],
            ratios: [1.5, -2.25, 0],
            flags: [true, false, true],
            small: [-128, 0, 127]
        )
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("an empty native array round-trips as empty")
    func emptyArrayRoundTrips() throws {
        struct Single: Codable, Equatable { let tags: [String] }
        let original = Single(tags: [])
        let columns = try ClickHouseRowEncoder().encode([original])
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("an empty non-String array keeps its element type, not Array(String)")
    func emptyNonStringArrayKeepsElementType() throws {
        struct Single: Codable, Equatable { let counts: [Int64] }
        let original = Single(counts: [])
        let columns = try ClickHouseRowEncoder().encode([original])
        // The decoder demands the column be Array(Int64); were the empty
        // array mis-tagged Array(String) the round trip would throw.
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: columns, rowCount: 1)
        #expect(decoded == [original])
    }

    @Test("multiple rows with differing array lengths encode and decode")
    func multipleRows() throws {
        struct Single: Codable, Equatable { let tags: [String] }
        let originals = [Single(tags: ["a"]), Single(tags: ["b", "c", "d"]), Single(tags: [])]
        let columns = try ClickHouseRowEncoder().encode(originals)
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Single.self, columns: columns, rowCount: originals.count)
        #expect(decoded == originals)
    }
}
