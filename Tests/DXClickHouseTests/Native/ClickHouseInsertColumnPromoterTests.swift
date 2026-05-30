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

@Suite("ClickHouse INSERT column promoter")
struct ClickHouseInsertColumnPromoterTests {

    @Test("identical specs return the source column unchanged")
    func passThrough() throws {
        let source: any ClickHouseColumn = ClickHouseStringColumn(values: ["a", "b"])
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: .string,
            columnName: "x"
        )
        let strings = try #require(promoted as? ClickHouseStringColumn)
        #expect(strings.values == ["a", "b"])
    }

    @Test("String values are wrapped into a deduplicating LowCardinality(String)")
    func stringToLowCardinalityString() throws {
        let source = ClickHouseStringColumn(values: ["alpha", "beta", "alpha", "gamma", "beta"])
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: .lowCardinality(of: .string),
            columnName: "env"
        )
        let lc = try #require(promoted as? ClickHouseLowCardinalityColumn)
        #expect(lc.spec == .lowCardinality(of: .string))
        #expect(lc.innerSpec == .string)
        let dictionary = try #require(lc.dictionary as? ClickHouseStringColumn)
        #expect(dictionary.values == ["alpha", "beta", "gamma"])
        #expect(lc.indices == [0, 1, 0, 2, 1])
    }

    @Test("String labels map to Enum8 codes via the schema's label table")
    func stringToEnum8() throws {
        let values: [ClickHouseEnumValue<Int8>] = [
            .init(name: "production", value: 1),
            .init(name: "staging", value: 2),
            .init(name: "development", value: 3),
        ]
        let source = ClickHouseStringColumn(values: ["staging", "production", "development", "staging"])
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: .enum8(values),
            columnName: "env"
        )
        let codes = try #require(promoted as? ClickHouseFixedWidthIntegerColumn<Int8>)
        #expect(codes.spec == .enum8(values))
        #expect(codes.values == [2, 1, 3, 2])
    }

    @Test("an Enum8 label not in the schema's label table surfaces a typed error")
    func enum8UnknownLabelThrows() throws {
        let values: [ClickHouseEnumValue<Int8>] = [
            .init(name: "production", value: 1),
            .init(name: "staging", value: 2),
        ]
        let source = ClickHouseStringColumn(values: ["production", "qa"])
        #expect(throws: ClickHouseError.insertEnumUnknownLabel(
            column: "env",
            label: "qa",
            allowedLabels: ["production", "staging"]
        )) {
            _ = try ClickHouseInsertColumnPromoter.promote(
                column: source,
                toMatch: .enum8(values),
                columnName: "env"
            )
        }
    }

    @Test("String labels map to Enum16 codes")
    func stringToEnum16() throws {
        let values: [ClickHouseEnumValue<Int16>] = [
            .init(name: "one", value: 101),
            .init(name: "two", value: 202),
        ]
        let source = ClickHouseStringColumn(values: ["two", "one", "two"])
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: .enum16(values),
            columnName: "code"
        )
        let codes = try #require(promoted as? ClickHouseFixedWidthIntegerColumn<Int16>)
        #expect(codes.values == [202, 101, 202])
    }

    @Test("Map(String, String) promotes to Map(LowCardinality(String), String) recursively")
    func mapStringStringToMapLCStringString() throws {
        let keys = ClickHouseStringColumn(values: ["service", "env", "service", "env"])
        let values = ClickHouseStringColumn(values: ["api", "prod", "worker", "stage"])
        let source = ClickHouseMapColumn(
            spec: .map(key: .string, value: .string),
            keySpec: .string,
            valueSpec: .string,
            offsets: [2, 4],
            keys: keys,
            values: values
        )
        let target: ClickHouseColumnSpec = .map(key: .lowCardinality(of: .string), value: .string)
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: target,
            columnName: "attributes"
        )
        let mapColumn = try #require(promoted as? ClickHouseMapColumn)
        #expect(mapColumn.spec == target)
        let promotedKeys = try #require(mapColumn.keys as? ClickHouseLowCardinalityColumn)
        let keyDictionary = try #require(promotedKeys.dictionary as? ClickHouseStringColumn)
        #expect(keyDictionary.values == ["service", "env"])
        #expect(promotedKeys.indices == [0, 1, 0, 1])
        let promotedValues = try #require(mapColumn.values as? ClickHouseStringColumn)
        #expect(promotedValues.values == ["api", "prod", "worker", "stage"])
    }

    @Test("Array(String) promotes to Array(LowCardinality(String))")
    func arrayStringToArrayLCString() throws {
        let inner = ClickHouseStringColumn(values: ["red", "blue", "red"])
        let source = ClickHouseArrayColumn(
            spec: .array(of: .string),
            elementSpec: .string,
            offsets: [2, 3],
            inner: inner
        )
        let target: ClickHouseColumnSpec = .array(of: .lowCardinality(of: .string))
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: target,
            columnName: "tags"
        )
        let arrayColumn = try #require(promoted as? ClickHouseArrayColumn)
        let lc = try #require(arrayColumn.inner as? ClickHouseLowCardinalityColumn)
        let dictionary = try #require(lc.dictionary as? ClickHouseStringColumn)
        #expect(dictionary.values == ["red", "blue"])
        #expect(lc.indices == [0, 1, 0])
    }

    @Test("Nullable(String) promotes to Nullable(LowCardinality(String))")
    func nullableStringToNullableLCString() throws {
        let inner = ClickHouseStringColumn(values: ["x", "", "y"])
        let source = ClickHouseNullableColumn(
            spec: .nullable(of: .string),
            innerSpec: .string,
            nullMask: [false, true, false],
            inner: inner
        )
        let target: ClickHouseColumnSpec = .nullable(of: .lowCardinality(of: .string))
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: target,
            columnName: "label"
        )
        let nullable = try #require(promoted as? ClickHouseNullableColumn)
        #expect(nullable.nullMask == [false, true, false])
        let lc = try #require(nullable.inner as? ClickHouseLowCardinalityColumn)
        let dictionary = try #require(lc.dictionary as? ClickHouseStringColumn)
        #expect(dictionary.values == ["x", "", "y"])
    }

    @Test("Tuple(String, String) promotes each element independently")
    func tupleStringStringToTupleEnum8String() throws {
        let enumValues: [ClickHouseEnumValue<Int8>] = [
            .init(name: "production", value: 1),
            .init(name: "staging", value: 2),
        ]
        let first = ClickHouseStringColumn(values: ["production", "staging"])
        let second = ClickHouseStringColumn(values: ["api", "worker"])
        let source = ClickHouseTupleColumn(
            spec: .tuple(elements: [.string, .string]),
            elementSpecs: [.string, .string],
            elements: [first, second],
            rowCount: 2
        )
        let target: ClickHouseColumnSpec = .tuple(elements: [.enum8(enumValues), .string])
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: target,
            columnName: "env_service"
        )
        let tuple = try #require(promoted as? ClickHouseTupleColumn)
        let enumCol = try #require(tuple.elements[0] as? ClickHouseFixedWidthIntegerColumn<Int8>)
        #expect(enumCol.values == [1, 2])
        let stringCol = try #require(tuple.elements[1] as? ClickHouseStringColumn)
        #expect(stringCol.values == ["api", "worker"])
    }

    @Test("a column count mismatch between client block and server sample surfaces a typed error")
    func columnCountMismatchThrows() throws {
        let clientBlock = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "a", column: ClickHouseStringColumn(values: ["x"])),
        ])
        let serverBlock = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "a", column: ClickHouseStringColumn(values: [])),
            .init(name: "b", column: ClickHouseStringColumn(values: [])),
        ])
        #expect(throws: ClickHouseError.insertColumnCountMismatch(client: 1, server: 2)) {
            _ = try ClickHouseInsertColumnPromoter.promote(block: clientBlock, toMatch: serverBlock)
        }
    }

    @Test("an unpromotable type pair surfaces a typed error naming the column")
    func unpromotableThrows() throws {
        let source = ClickHouseFloat64Column(values: [1.0])
        #expect(throws: ClickHouseError.insertColumnTypeUnpromotable(
            column: "n",
            from: .float64,
            to: .string
        )) {
            _ = try ClickHouseInsertColumnPromoter.promote(
                column: source,
                toMatch: .string,
                columnName: "n"
            )
        }
    }

    @Test("an already-LowCardinality column passes through unchanged when specs match")
    func alreadyLowCardinalityPassesThrough() throws {
        let inner = ClickHouseStringColumn(values: ["a", "b"])
        let source = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: inner,
            indices: [0, 1]
        )
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: .lowCardinality(of: .string),
            columnName: "x"
        )
        let lc = try #require(promoted as? ClickHouseLowCardinalityColumn)
        let dictionary = try #require(lc.dictionary as? ClickHouseStringColumn)
        #expect(dictionary.values == ["a", "b"])
        #expect(lc.indices == [0, 1])
    }

    @Test("DateTime64 columns whose only difference is the timezone metadata are passed through with the server's spec applied")
    func dateTime64TimezoneMetadataRestamps() throws {
        let source = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 9, timezone: .serverDefault),
            values: [1_700_000_000_000_000_000, 1_700_000_000_500_000_000]
        )
        let target: ClickHouseColumnSpec = .dateTime64(precision: 9, timezone: .explicit("UTC"))
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: target,
            columnName: "ts"
        )
        let restamped = try #require(promoted as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(restamped.spec == target)
        #expect(restamped.values == [1_700_000_000_000_000_000, 1_700_000_000_500_000_000])
    }

    @Test("DateTime64 columns with different precision must still fail — different precision means different wire bytes")
    func dateTime64PrecisionMismatchFails() throws {
        let source = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: 9, timezone: .serverDefault),
            values: [0]
        )
        let target: ClickHouseColumnSpec = .dateTime64(precision: 6, timezone: .explicit("UTC"))
        #expect(throws: (any Error).self) {
            _ = try ClickHouseInsertColumnPromoter.promote(
                column: source,
                toMatch: target,
                columnName: "ts"
            )
        }
    }

    @Test("DateTime columns get the server's timezone stamped onto the column spec")
    func dateTimeTimezoneRestamps() throws {
        let source = ClickHouseFixedWidthIntegerColumn<UInt32>(
            spec: .dateTime(timezone: .serverDefault),
            values: [1_700_000_000, 1_700_000_001]
        )
        let target: ClickHouseColumnSpec = .dateTime(timezone: .explicit("Pacific/Auckland"))
        let promoted = try ClickHouseInsertColumnPromoter.promote(
            column: source,
            toMatch: target,
            columnName: "ts"
        )
        let restamped = try #require(promoted as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(restamped.spec == target)
        #expect(restamped.values == [1_700_000_000, 1_700_000_001])
    }

    @Test("promote(block:toMatch:) preserves block info and column names")
    func blockLevelPromotionPreservesNamesAndInfo() throws {
        var blockInfo = ClickHouseBlockInfo()
        blockInfo.bucketNumber = 7
        let clientBlock = ClickHouseBlock(blockInfo: blockInfo, columns: [
            .init(name: "id", column: ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: [10, 20])),
            .init(name: "env", column: ClickHouseStringColumn(values: ["prod", "stage"])),
        ])
        let serverBlock = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "id", column: ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: [])),
            .init(name: "env", column: ClickHouseLowCardinalityColumn(
                spec: .lowCardinality(of: .string),
                innerSpec: .string,
                dictionary: ClickHouseStringColumn(values: []),
                indices: []
            )),
        ])
        let promoted = try ClickHouseInsertColumnPromoter.promote(block: clientBlock, toMatch: serverBlock)
        #expect(promoted.blockInfo.bucketNumber == 7)
        #expect(promoted.columns.map(\.name) == ["id", "env"])
        let idColumn = try #require(promoted.columns[0].column as? ClickHouseFixedWidthIntegerColumn<UInt64>)
        #expect(idColumn.values == [10, 20])
        let envColumn = try #require(promoted.columns[1].column as? ClickHouseLowCardinalityColumn)
        let envDictionary = try #require(envColumn.dictionary as? ClickHouseStringColumn)
        #expect(envDictionary.values == ["prod", "stage"])
    }

}
