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
import NIOCore
import Testing

@Suite("ClickHouse tuple column")
struct TupleColumnTests {

    @Test("Tuple(Int32, String) round-trips column-oriented")
    func tupleOfIntAndString() throws {
        let elements: [any ClickHouseColumn] = [
            ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [10, 20, 30]),
            ClickHouseStringColumn(values: ["alpha", "beta", "gamma"]),
        ]
        let column = ClickHouseTupleColumn(
            spec: .tuple(elements: [.int32, .string]),
            elementSpecs: [.int32, .string],
            elements: elements,
            rowCount: 3
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseTupleColumn.decode(elementSpecs: [.int32, .string], rows: 3, from: &buffer)
        let firstColumn = try #require(decoded.elements[0] as? ClickHouseFixedWidthIntegerColumn<Int32>)
        let secondColumn = try #require(decoded.elements[1] as? ClickHouseStringColumn)
        #expect(firstColumn.values == [10, 20, 30])
        #expect(secondColumn.values == ["alpha", "beta", "gamma"])
        #expect(buffer.readableBytes == 0)
    }

    @Test("encode rejects an element whose row count diverges from the tuple")
    func divergentElementRowCountRejected() {
        let column = ClickHouseTupleColumn(
            spec: .tuple(elements: [.int32, .string]),
            elementSpecs: [.int32, .string],
            elements: [
                ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2, 3]),
                ClickHouseStringColumn(values: ["a", "b"]),
            ],
            rowCount: 3
        )
        var buffer = ByteBuffer()
        #expect {
            try column.encode(into: &buffer)
        } throws: { error in
            guard case ClickHouseError.tupleInnerRowCountMismatch(let index, let expected, let actual) = error else {
                return false
            }
            return index == 1 && expected == 3 && actual == 2
        }
    }

    @Test("encode rejects when element count diverges from spec count")
    func divergentElementCountRejected() {
        let column = ClickHouseTupleColumn(
            spec: .tuple(elements: [.int32, .string, .bool]),
            elementSpecs: [.int32, .string, .bool],
            elements: [
                ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1]),
                ClickHouseStringColumn(values: ["a"]),
            ],
            rowCount: 1
        )
        var buffer = ByteBuffer()
        #expect {
            try column.encode(into: &buffer)
        } throws: { error in
            guard case ClickHouseError.tupleElementCountMismatch(let expected, let actual) = error else {
                return false
            }
            return expected == 3 && actual == 2
        }
    }

    @Test("zero-row Tuple consumes zero bytes per element")
    func zeroRowTuple() throws {
        let column = ClickHouseTupleColumn(
            spec: .tuple(elements: [.int32, .string]),
            elementSpecs: [.int32, .string],
            elements: [
                ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: []),
                ClickHouseStringColumn(values: []),
            ],
            rowCount: 0
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 0)

        let decoded = try ClickHouseTupleColumn.decode(elementSpecs: [.int32, .string], rows: 0, from: &buffer)
        #expect(decoded.rowCount == 0)
        #expect(decoded.elements.count == 2)
    }

    @Test("registry decode of Tuple preserves spec ordering")
    func registryDispatchPreservesElementOrder() throws {
        let elements: [any ClickHouseColumn] = [
            ClickHouseBoolColumn(values: [true, false]),
            ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [-1, 1]),
        ]
        let column = ClickHouseTupleColumn(
            spec: .tuple(elements: [.bool, .int64]),
            elementSpecs: [.bool, .int64],
            elements: elements,
            rowCount: 2
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .tuple(elements: [.bool, .int64]),
            rows: 2,
            from: &buffer
        )
        let typed = try #require(decoded as? ClickHouseTupleColumn)
        #expect(typed.elementSpecs == [.bool, .int64])
        let bools = try #require(typed.elements[0] as? ClickHouseBoolColumn)
        let ints = try #require(typed.elements[1] as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(bools.values == [true, false])
        #expect(ints.values == [-1, 1])
    }

}
