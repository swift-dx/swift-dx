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

import NIOCore

// CH `Tuple(T1, T2, ...)` wire layout:
//   Each element column is written sequentially, all sharing the same
//   row count as the tuple itself. There is no length prefix or marker
//   between elements; the type metadata in the spec is what tells the
//   reader how to delimit.
struct ClickHouseTupleColumn: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    let elementSpecs: [ClickHouseColumnSpec]
    var elements: [any ClickHouseColumn]
    let rowCount: Int

    func encodePrefix(into buffer: inout ByteBuffer) throws {
        for element in elements {
            try element.encodePrefix(into: &buffer)
        }
    }

    func encode(into buffer: inout ByteBuffer) throws {
        guard elements.count == elementSpecs.count else {
            throw ClickHouseError.tupleElementCountMismatch(
                expected: elementSpecs.count,
                actual: elements.count
            )
        }
        for (index, element) in elements.enumerated() {
            try encodeTupleElement(index: index, element: element, into: &buffer)
        }
    }

    private func encodeTupleElement(index: Int, element: any ClickHouseColumn, into buffer: inout ByteBuffer) throws {
        guard element.rowCount == rowCount else {
            throw ClickHouseError.tupleInnerRowCountMismatch(
                elementIndex: index,
                expected: rowCount,
                actual: element.rowCount
            )
        }
        try element.encode(into: &buffer)
    }

    static func decode(elementSpecs: [ClickHouseColumnSpec], rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        var elements: [any ClickHouseColumn] = []
        elements.reserveCapacity(elementSpecs.count)
        for (elementIndex, elementSpec) in elementSpecs.enumerated() {
            let column = try ClickHouseColumnRegistry.decode(spec: elementSpec, rows: rows, from: &buffer)
            // Defense-in-depth: every tuple element must contain the
            // same number of rows as the tuple itself. A drifted inner
            // codec would otherwise leave callers indexing `tuple
            // .elements[i]` past its backing storage when iterating
            // by `tuple.rowCount`.
            guard column.rowCount == rows else {
                throw ClickHouseError.tupleInnerRowCountMismatch(
                    elementIndex: elementIndex,
                    expected: rows,
                    actual: column.rowCount
                )
            }
            elements.append(column)
        }
        return .init(
            spec: .tuple(elements: elementSpecs),
            elementSpecs: elementSpecs,
            elements: elements,
            rowCount: rows
        )
    }

}
