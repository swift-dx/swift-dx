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

import Foundation

// The materialised result of an arbitrary query, read column-by-column with
// no Codable type and no conformance required — the thinnest typed layer over
// the native protocol. `query(_:)` returns one of these for any SELECT; the
// caller reads each column's values directly by name and row index.
//
// Values are held as the parsed typed columns of every result block; an
// accessor locates the block a global row falls in and reads the value in
// place. Each accessor throws if the named column has a different type, so a
// wrong read surfaces as a typed error rather than a silent reinterpretation.
public struct ClickHouseQueryResult: Sendable {

    public let columnNames: [String]
    public let columnTypes: [String]
    public let rowCount: Int

    package let blocks: [[ClickHouseTypedColumn]]
    package let blockOffsets: [Int]
    package let indexByName: [String: Int]

    package init(columnNames: [String], columnTypes: [String], rowCount: Int, blocks: [[ClickHouseTypedColumn]], blockOffsets: [Int]) {
        self.columnNames = columnNames
        self.columnTypes = columnTypes
        self.rowCount = rowCount
        self.blocks = blocks
        self.blockOffsets = blockOffsets
        var index: [String: Int] = [:]
        index.reserveCapacity(columnNames.count)
        for (position, name) in columnNames.enumerated() { index[name] = position }
        self.indexByName = index
    }

    // Whether the value at the column and row is SQL NULL. A non-nullable
    // column is never NULL. Check this before an accessor when the column is
    // Nullable: the typed accessors throw on a NULL value (there is no
    // optional return — see the No-Optionals rule).
    public func isNull(_ column: String, _ row: Int) throws(ClickHouseError) -> Bool {
        let address = try locate(column, row)
        return blocks[address.block][address.column].isNull(at: address.local)
    }

    public func uint64(_ column: String, _ row: Int) throws(ClickHouseError) -> UInt64 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .uint64(let values): return values[address.local]
        case .nullableUInt64(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "UInt64")
        }
    }

    public func int64(_ column: String, _ row: Int) throws(ClickHouseError) -> Int64 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .int64(let values): return values[address.local]
        case .nullableInt64(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Int64")
        }
    }

    public func uint32(_ column: String, _ row: Int) throws(ClickHouseError) -> UInt32 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .uint32(let values): return values[address.local]
        case .nullableUInt32(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "UInt32")
        }
    }

    public func int32(_ column: String, _ row: Int) throws(ClickHouseError) -> Int32 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .int32(let values): return values[address.local]
        case .nullableInt32(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Int32")
        }
    }

    public func uint16(_ column: String, _ row: Int) throws(ClickHouseError) -> UInt16 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .uint16(let values): return values[address.local]
        case .nullableUInt16(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "UInt16")
        }
    }

    public func int16(_ column: String, _ row: Int) throws(ClickHouseError) -> Int16 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .int16(let values): return values[address.local]
        case .nullableInt16(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Int16")
        }
    }

    public func uint8(_ column: String, _ row: Int) throws(ClickHouseError) -> UInt8 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .uint8(let values): return values[address.local]
        case .nullableUInt8(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "UInt8")
        }
    }

    public func int8(_ column: String, _ row: Int) throws(ClickHouseError) -> Int8 {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .int8(let values): return values[address.local]
        case .nullableInt8(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Int8")
        }
    }

    public func double(_ column: String, _ row: Int) throws(ClickHouseError) -> Double {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .float64(let values): return values[address.local]
        case .nullableFloat64(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Float64")
        }
    }

    public func float(_ column: String, _ row: Int) throws(ClickHouseError) -> Float {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .float32(let values): return values[address.local]
        case .nullableFloat32(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Float32")
        }
    }

    public func bool(_ column: String, _ row: Int) throws(ClickHouseError) -> Bool {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .bool(let values): return values[address.local]
        case .nullableBool(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Bool")
        }
    }

    // Reads a String column, transparently handling LowCardinality(String)
    // (dictionary-encoded storage, the recommended form for low-cardinality
    // text) and Enum columns (returned as the matching name).
    public func string(_ column: String, _ row: Int) throws(ClickHouseError) -> String {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .string(let values): return ClickHouseUTF8.decode(values[address.local])
        case .nullableString(let values): return ClickHouseUTF8.decode(try Self.present(values[address.local], column))
        case .fixedString(let values, let length): return ClickHouseFixedString(bytes: values[address.local], length: length).text
        case .lowCardinality(let values, .string): return ClickHouseUTF8.decode(values[address.local])
        case .lowCardinality(let values, .fixedString(let length)): return ClickHouseFixedString(bytes: values[address.local], length: length).text
        case .enum8(let values, let mapping): return try Self.enumName(Int16(values[address.local]), mapping, column)
        case .enum16(let values, let mapping): return try Self.enumName(values[address.local], mapping, column)
        default: throw Self.mismatch(column, "String")
        }
    }

    // Reads the raw bytes of a String, FixedString, or LowCardinality column —
    // the binary-safe path (no UTF-8 interpretation).
    public func bytes(_ column: String, _ row: Int) throws(ClickHouseError) -> [UInt8] {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .string(let values): return values[address.local]
        case .nullableString(let values): return try Self.present(values[address.local], column)
        case .fixedString(let values, _): return values[address.local]
        case .lowCardinality(let values, _): return values[address.local]
        default: throw Self.mismatch(column, "String bytes")
        }
    }

    private static func enumName(_ value: Int16, _ mapping: [ClickHouseEnumPair], _ column: String) throws(ClickHouseError) -> String {
        for pair in mapping where pair.value == value { return pair.name }
        throw .protocolError(stage: "queryResult", message: "enum value \(value) for column '\(column)' is not in the mapping")
    }

    // Resolves each array element's stored Enum value (`T` is Int8 for Enum8,
    // Int16 for Enum16) to its name, so an Array(Enum) reads as its names the
    // same way a scalar Enum column does through `string`.
    private static func enumNameArray<T: FixedWidthInteger>(_ elements: [[UInt8]], as type: T.Type, mapping: [ClickHouseEnumPair], column: String) throws(ClickHouseError) -> [String] {
        var names: [String] = []
        names.reserveCapacity(elements.count)
        for element in elements {
            names.append(try enumName(Int16(loadLittleEndian(element) as T), mapping, column))
        }
        return names
    }

    // Reads any temporal column (DateTime, DateTime64, Date, Date32) as an
    // absolute instant. DateTime64 ticks scale by the column precision; Date
    // and Date32 days scale by seconds-per-day.
    public func date(_ column: String, _ row: Int) throws(ClickHouseError) -> Date {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .dateTime(let values): return values[address.local]
        case .dateTime64(let values, let precision): return Date(timeIntervalSince1970: Double(values[address.local]) / pow(10.0, Double(precision)))
        case .date(let values): return Date(timeIntervalSince1970: TimeInterval(values[address.local]) * 86_400)
        case .date32(let values): return Date(timeIntervalSince1970: TimeInterval(values[address.local]) * 86_400)
        case .nullableDateTime(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "Date/DateTime")
        }
    }

    public func uuid(_ column: String, _ row: Int) throws(ClickHouseError) -> UUID {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .uuid(let values): return values[address.local]
        case .nullableUUID(let values): return try Self.present(values[address.local], column)
        default: throw Self.mismatch(column, "UUID")
        }
    }

    public func decimal(_ column: String, _ row: Int) throws(ClickHouseError) -> ClickHouseDecimal {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .decimal(let values, _, _): return values[address.local]
        default: throw Self.mismatch(column, "Decimal")
        }
    }

    // Reads an Array(String) column as the row's array of strings (tag arrays
    // and the like — a common ClickHouse shape).
    public func stringArray(_ column: String, _ row: Int) throws(ClickHouseError) -> [String] {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .array(let perRow, .string): return perRow[address.local].map { ClickHouseUTF8.decode($0) }
        case .array(let perRow, .fixedString(let length)): return perRow[address.local].map { ClickHouseFixedString(bytes: $0, length: length).text }
        case .array(let perRow, .enum8(let mapping)): return try Self.enumNameArray(perRow[address.local], as: Int8.self, mapping: mapping, column: column)
        case .array(let perRow, .enum16(let mapping)): return try Self.enumNameArray(perRow[address.local], as: Int16.self, mapping: mapping, column: column)
        default: throw Self.mismatch(column, "Array(String)")
        }
    }

    public func int64Array(_ column: String, _ row: Int) throws(ClickHouseError) -> [Int64] {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .array(let perRow, .int64): return perRow[address.local].map { Int64(bitPattern: Self.loadLittleEndian($0)) }
        default: throw Self.mismatch(column, "Array(Int64)")
        }
    }

    public func uint64Array(_ column: String, _ row: Int) throws(ClickHouseError) -> [UInt64] {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .array(let perRow, .uint64): return perRow[address.local].map { Self.loadLittleEndian($0) as UInt64 }
        default: throw Self.mismatch(column, "Array(UInt64)")
        }
    }

    public func doubleArray(_ column: String, _ row: Int) throws(ClickHouseError) -> [Double] {
        let address = try locate(column, row)
        switch try Self.unwrapped(blocks[address.block][address.column], address.local, column) {
        case .array(let perRow, .float64): return perRow[address.local].map { Double(bitPattern: Self.loadLittleEndian($0)) }
        default: throw Self.mismatch(column, "Array(Float64)")
        }
    }

    private static func loadLittleEndian<T: FixedWidthInteger>(_ bytes: [UInt8]) -> T {
        bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    // Unwraps the generic Nullable wrapper (used for types without a dedicated
    // nullable column case — Decimal, DateTime64, Date, etc.) to its inner
    // column, throwing if the value is NULL. Columns that are not the generic
    // wrapper (plain columns and the dedicated nullable cases) pass through
    // unchanged. The inner column shares the same row index.
    private static func unwrapped(_ column: ClickHouseTypedColumn, _ local: Int, _ name: String) throws(ClickHouseError) -> ClickHouseTypedColumn {
        guard case .nullable(let mask, let inner) = column else { return column }
        guard !mask[local] else {
            throw .protocolError(stage: "queryResult", message: "column '\(name)' is NULL at this row; check isNull first")
        }
        return inner
    }

    private static func present<Value>(_ value: ClickHouseNullable<Value>, _ column: String) throws(ClickHouseError) -> Value {
        switch value {
        case .present(let inner): return inner
        case .absent: throw .protocolError(stage: "queryResult", message: "column '\(column)' is NULL at this row; check isNull first")
        }
    }

    private func locate(_ column: String, _ row: Int) throws(ClickHouseError) -> (block: Int, local: Int, column: Int) {
        guard let columnIndex = indexByName[column] else {
            throw .protocolError(stage: "queryResult", message: "no column named '\(column)'")
        }
        guard (0..<rowCount).contains(row) else {
            throw .protocolError(stage: "queryResult", message: "row \(row) out of range 0..<\(rowCount)")
        }
        let block = blockContaining(row)
        return (block, row - blockOffsets[block], columnIndex)
    }

    private func blockContaining(_ row: Int) -> Int {
        var block = 0
        while block + 1 < blockOffsets.count, blockOffsets[block + 1] <= row { block += 1 }
        return block
    }

    private static func mismatch(_ column: String, _ expected: String) -> ClickHouseError {
        .protocolError(stage: "queryResult", message: "column '\(column)' is not \(expected)")
    }
}
