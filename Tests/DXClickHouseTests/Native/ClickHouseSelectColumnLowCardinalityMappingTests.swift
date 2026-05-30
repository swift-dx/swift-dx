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
import Testing

@Suite("ClickHouseSelectColumn — LowCardinality(T) mapping")
struct ClickHouseSelectColumnLowCardinalityMappingTests {

    private static func makeLowCardinality<T: ClickHouseColumn>(
        innerSpec: ClickHouseColumnSpec, dictionary: T, indices: [UInt64]
    ) -> ClickHouseLowCardinalityColumn {
        ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: innerSpec),
            innerSpec: innerSpec,
            dictionary: dictionary,
            indices: indices
        )
    }

    private static func materialise(_ view: ClickHouseLowCardinalityStringView) -> [String] {
        var result = [String]()
        result.reserveCapacity(view.count)
        for rowIndex in 0..<view.count { result.append(view[rowIndex]) }
        return result
    }

    @Test("LowCardinality(String) resolves indices to dictionary entries")
    func lowCardinalityStringMapping() throws {
        // 5 rows from a dictionary of 3 unique strings
        let column = Self.makeLowCardinality(
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["NZ", "AU", "US"]),
            indices: [0, 1, 0, 2, 0]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "country", internalColumn: column)
        guard case .lowCardinalityStringIndexed(let view) = publicColumn.values else {
            Issue.record("expected .lowCardinalityStringIndexed case")
            return
        }
        #expect(Self.materialise(view) == ["NZ", "AU", "NZ", "US", "NZ"])
        #expect(view.dictionary == ["NZ", "AU", "US"])
    }

    @Test("LowCardinality(String) with no rows produces an empty view")
    func emptyLowCardinalityColumn() throws {
        let column = Self.makeLowCardinality(
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: []),
            indices: []
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        guard case .lowCardinalityStringIndexed(let view) = publicColumn.values else {
            Issue.record("expected .lowCardinalityStringIndexed case")
            return
        }
        #expect(view.count == 0)
        #expect(view.dictionary.isEmpty)
    }

    @Test("LowCardinality(String) with one dictionary entry produces a uniform-value view")
    func uniformLowCardinalityColumn() throws {
        let column = Self.makeLowCardinality(
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["pending"]),
            indices: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "status", internalColumn: column)
        guard case .lowCardinalityStringIndexed(let view) = publicColumn.values else {
            Issue.record("expected .lowCardinalityStringIndexed case")
            return
        }
        #expect(view.count == 10)
        #expect(view.dictionary == ["pending"])
        #expect(Self.materialise(view).allSatisfy { $0 == "pending" })
    }

    @Test("LowCardinality(String) with an out-of-range index throws lowCardinalityDictionaryIndexOutOfRange with the offending index and dictionary size")
    func outOfRangeIndexThrows() throws {
        let column = Self.makeLowCardinality(
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["a", "b"]),
            indices: [0, 1, 99]
        )
        #expect(throws: ClickHouseError.lowCardinalityDictionaryIndexOutOfRange(index: 99, dictionarySize: 2)) {
            try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        }
    }

    @Test("LowCardinality(String) with an index value > Int.max (hostile/buggy peer emitting UInt64 keyType with overflowing payload) throws lowCardinalityDictionaryIndexOutOfRange rather than trapping the process. Pre-fix the column-mapping path used raw `Int(_:)` which traps on UInt64 > Int.max — taking the entire event loop down for a single corrupt column. The parallel JSON-encoder path (used by `decodedRows`) already guarded with `Int(exactly:)`; this test pins the same defense on the typed select-mapping path so the two surfaces stay aligned.")
    func indexExceedsIntMaxThrowsTyped() throws {
        // CH defaults bound LC dictionaries at ~8K entries and use
        // narrow-width indices, so this magnitude only ever arises from
        // a malformed peer. Use UInt64.max as the most extreme case.
        let column = Self.makeLowCardinality(
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["a", "b"]),
            indices: [UInt64.max]
        )
        var thrown: Error?
        do {
            _ = try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "must throw rather than trap on UInt64 index > Int.max")
        guard case ClickHouseError.lowCardinalityDictionaryIndexOutOfRange(_, let dictSize) = received else {
            Issue.record("expected lowCardinalityDictionaryIndexOutOfRange; got \(received)")
            return
        }
        #expect(dictSize == 2, "the dictionary size must be carried for diagnostics")
    }

    @Test("LowCardinality(Int32) throws unsupportedSelectColumnType (mapping limitation, not wire corruption)")
    func nonStringLowCardinalityThrows() throws {
        let column = Self.makeLowCardinality(
            innerSpec: .int32,
            dictionary: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [10, 20]),
            indices: [0, 1]
        )
        #expect(throws: ClickHouseError.unsupportedSelectColumnType(typeName: "LowCardinality(Int32)")) {
            try ClickHouseSelectColumn.from(name: "x", internalColumn: column)
        }
    }

    @Test("LowCardinality(String) wire round-trips for non-empty data")
    func wireRoundTrip() throws {
        let original = Self.makeLowCardinality(
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: ["alpha", "beta", "gamma"]),
            indices: [0, 1, 2, 1, 0]
        )
        var buffer = ByteBuffer()
        try original.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .lowCardinality(of: .string), rows: 5, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "lc", internalColumn: decoded)

        guard case .lowCardinalityStringIndexed(let view) = publicColumn.values else {
            Issue.record("expected .lowCardinalityStringIndexed case")
            return
        }
        #expect(Self.materialise(view) == ["alpha", "beta", "gamma", "beta", "alpha"])
        #expect(buffer.readableBytes == 0)
    }

    @Test("LowCardinality(String) wire round-trips for the empty case (zero bytes)")
    func emptyWireRoundTrip() throws {
        let original = Self.makeLowCardinality(
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: []),
            indices: []
        )
        var buffer = ByteBuffer()
        try original.encode(into: &buffer)
        // Empty rows are special: nothing written at all.
        #expect(buffer.readableBytes == 0)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .lowCardinality(of: .string), rows: 0, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "lc", internalColumn: decoded)

        guard case .lowCardinalityStringIndexed(let view) = publicColumn.values else {
            Issue.record("expected .lowCardinalityStringIndexed case")
            return
        }
        #expect(view.count == 0)
    }

    @Test("LowCardinality(String) end-to-end: INSERT-side toInternalColumn round-trips through the SELECT-side mapper")
    func insertSideAndSelectSideAreSymmetric() throws {
        let original: [String] = ["NZ", "AU", "NZ", "US", "AU", "NZ"]
        let internalColumn = try ClickHouseClient.toInternalColumn(.lowCardinalityString(original))
        let typed = try #require(internalColumn as? ClickHouseLowCardinalityColumn)

        // Encode through the wire and decode back, then map to public Values.
        var buffer = ByteBuffer()
        try typed.encode(into: &buffer)
        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .lowCardinality(of: .string), rows: original.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "country", internalColumn: decoded)

        guard case .lowCardinalityStringIndexed(let view) = publicColumn.values else {
            Issue.record("expected .lowCardinalityStringIndexed case")
            return
        }
        #expect(Self.materialise(view) == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("LowCardinality(String) preserves dictionary deduplication on INSERT — fewer dictionary entries than rows")
    func insertSideDeduplicates() throws {
        let original: [String] = ["pending", "pending", "approved", "pending", "approved", "rejected"]
        let internalColumn = try ClickHouseClient.toInternalColumn(.lowCardinalityString(original))
        let typed = try #require(internalColumn as? ClickHouseLowCardinalityColumn)
        let dictionary = try #require(typed.dictionary as? ClickHouseStringColumn)
        // 6 rows but only 3 unique values
        #expect(dictionary.values.count == 3)
        #expect(typed.indices.count == original.count)
    }

}
