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

@Suite("ClickHouse row JSON encoder")
struct ClickHouseRowJSONEncoderTests {

    @Test("primitive Int and String columns serialize as JSON number and string")
    func intAndStringRow() throws {
        let block = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "n", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [42, 0, -7])),
            .init(name: "s", column: ClickHouseStringColumn(values: ["alpha", "beta", "gamma"])),
        ])

        struct Row: Decodable, Equatable {

            let n: Int32
            let s: String

        }

        let rows = try (0..<block.rowCount).map { rowIndex in
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
            return try JSONDecoder().decode(Row.self, from: payload)
        }
        #expect(rows == [
            .init(n: 42, s: "alpha"),
            .init(n: 0, s: "beta"),
            .init(n: -7, s: "gamma"),
        ])
    }

    @Test("UInt64 values above Int64.max preserve precision through the JSON bridge")
    func uint64HighRange() throws {
        let column = ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: [.max, 0, 18_446_744_073_709_551_614])
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "u", column: column)])

        struct Row: Decodable, Equatable {

            let u: UInt64

        }

        let rows = try (0..<block.rowCount).map { rowIndex in
            try JSONDecoder().decode(
                Row.self,
                from: try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
            )
        }
        #expect(rows.map(\.u) == [.max, 0, 18_446_744_073_709_551_614])
    }

    @Test("Bool, Float64 and UUID round-trip through standard JSONDecoder")
    func mixedPrimitives() throws {
        let uuid = UUID()
        let column1 = ClickHouseBoolColumn(values: [true, false])
        let column2 = ClickHouseFloat64Column(values: [3.14159, -0.5])
        let column3 = ClickHouseUUIDColumn(values: [uuid, UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))])
        let block = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "flag", column: column1),
            .init(name: "ratio", column: column2),
            .init(name: "id", column: column3),
        ])

        struct Row: Decodable, Equatable {

            let flag: Bool
            let ratio: Double
            let id: UUID

        }

        let rows = try (0..<block.rowCount).map { rowIndex in
            try JSONDecoder().decode(
                Row.self,
                from: try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
            )
        }
        #expect(rows[0].flag == true)
        #expect(rows[0].ratio == 3.14159)
        #expect(rows[0].id == uuid)
        #expect(rows[1].flag == false)
        #expect(rows[1].ratio == -0.5)
    }

    @Test("Nullable columns surface null for null rows and the typed value otherwise")
    func nullableHandling() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [10, 0, 30])
        let nullable = ClickHouseNullableColumn(
            spec: .nullable(of: .int32),
            innerSpec: .int32,
            nullMask: [false, true, false],
            inner: inner
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "n", column: nullable)])

        struct Row: Decodable, Equatable {

            let n: Int32?

        }

        let rows = try (0..<block.rowCount).map { rowIndex in
            try JSONDecoder().decode(
                Row.self,
                from: try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
            )
        }
        #expect(rows.map(\.n) == [10, nil, 30])
    }

    @Test("Array(String) rows produce JSON arrays with the correct slice per row")
    func arrayOfStrings() throws {
        let inner = ClickHouseStringColumn(values: ["red", "green", "blue", "white", "black"])
        let array = ClickHouseArrayColumn(
            spec: .array(of: .string),
            elementSpec: .string,
            offsets: [2, 2, 5],
            inner: inner
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "tags", column: array)])

        struct Row: Decodable, Equatable {

            let tags: [String]

        }

        let rows = try (0..<block.rowCount).map { rowIndex in
            try JSONDecoder().decode(
                Row.self,
                from: try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
            )
        }
        #expect(rows.map(\.tags) == [
            ["red", "green"],
            [],
            ["blue", "white", "black"],
        ])
    }

    @Test("LowCardinality(String) emits the dictionary value at the row's index")
    func lowCardinalityResolvesViaDictionary() throws {
        let dictionary = ClickHouseStringColumn(values: ["", "alpha", "beta"])
        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: dictionary,
            indices: [1, 2, 1]
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "code", column: column)])

        struct Row: Decodable, Equatable {

            let code: String

        }

        let rows = try (0..<block.rowCount).map { rowIndex in
            try JSONDecoder().decode(
                Row.self,
                from: try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
            )
        }
        #expect(rows.map(\.code) == ["alpha", "beta", "alpha"])
    }

    @Test("Tuple columns serialize as JSON arrays of element values")
    func tupleAsArray() throws {
        let element1 = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2])
        let element2 = ClickHouseStringColumn(values: ["a", "b"])
        let tuple = ClickHouseTupleColumn(
            spec: .tuple(elements: [.int32, .string]),
            elementSpecs: [.int32, .string],
            elements: [element1, element2],
            rowCount: 2
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "t", column: tuple)])

        let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: 0)
        let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let elements = try #require(parsed?["t"] as? [Any])
        #expect((elements[0] as? Int) == 1)
        #expect((elements[1] as? String) == "a")
    }

    @Test("Map(String, Int32) rows surface as JSON objects keyed by string")
    func mapAsObject() throws {
        let keys = ClickHouseStringColumn(values: ["one", "two", "three"])
        let values = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3])
        let map = ClickHouseMapColumn(
            spec: .map(key: .string, value: .int32),
            keySpec: .string,
            valueSpec: .int32,
            offsets: [2, 3],
            keys: keys,
            values: values
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "m", column: map)])

        struct Row: Decodable, Equatable {

            let m: [String: Int32]

        }

        let rows = try (0..<block.rowCount).map { rowIndex in
            try JSONDecoder().decode(
                Row.self,
                from: try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
            )
        }
        #expect(rows[0].m == ["one": 1, "two": 2])
        #expect(rows[1].m == ["three": 3])
    }

    @Test("an out-of-range row index surfaces a typed error rather than crashing")
    func outOfRangeRowThrows() {
        let block = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "n", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])),
        ])
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: 5)
        }
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: -1)
        }
    }

    @Test("an unsupported column type surfaces unsupportedJSONColumnType")
    func unsupportedColumnTypeThrows() {
        let column = ClickHouseInt256Column(spec: .int256, values: [.zero])
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "x", column: column)])
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: 0)
        }
    }

    @Test("NaN in a Float64 column surfaces a typed error with row index, not an opaque NSError from Foundation's JSON path")
    func nanFloat64SurfacesTypedError() {
        // JSONSerialization rejects NaN/Infinity with a generic
        // "Invalid number" NSError that carries no row information
        // and stack-traces deep into Foundation. The encoder must
        // detect non-finite floats upfront and throw a typed error
        // identifying the row, so callers (and operators) can locate
        // the offending value in the result set and either filter
        // server-side or use a lower-level API that preserves the
        // exact bit pattern.
        let column = ClickHouseFloat64Column(values: [1.0, .nan, .infinity])
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "v", column: column)])

        var thrown: Error?
        do {
            _ = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: 1)
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        #expect(
            received == .nonFiniteFloatInJSONOutput(textualValue: "nan", row: 1),
            "expected typed nonFiniteFloat error for NaN at row 1, got \(String(describing: thrown))"
        )

        var infThrown: Error?
        do {
            _ = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: 2)
        } catch {
            infThrown = error
        }
        let infReceived = infThrown as? ClickHouseError
        #expect(
            infReceived == .nonFiniteFloatInJSONOutput(textualValue: "inf", row: 2),
            "expected typed nonFiniteFloat error for +Infinity at row 2, got \(String(describing: infThrown))"
        )

        // Sanity: the finite row encodes as a normal JSON number.
        #expect(throws: Never.self) {
            _ = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: 0)
        }
    }

    @Test("LowCardinality with an out-of-range dictionary index throws rather than crashing the process")
    func lowCardinalityIndexOutOfRangeThrows() {
        // A malformed LowCardinality column whose `indices[row]` points
        // past `dictionary.rowCount` would otherwise drive an Array
        // out-of-bounds trap deep inside the encoder (a fatalError,
        // not a throw — the whole process dies). The encoder MUST
        // surface this as a typed error so a single corrupt block
        // cannot DoS a 24/7 service.
        let dictionary = ClickHouseStringColumn(values: ["", "alpha"])  // size 2
        let column = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: dictionary,
            indices: [5]  // out of range: 5 >= 2
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "code", column: column)])

        var thrown: Error?
        do {
            _ = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: 0)
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        #expect(
            received == .lowCardinalityDictionaryIndexOutOfRange(index: 5, dictionarySize: 2),
            "expected lowCardinalityDictionaryIndexOutOfRange(5, 2), got \(String(describing: thrown))"
        )
    }

}
