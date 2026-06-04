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

/// One row of a result set. Columns are addressed by position or by name; values
/// are decoded into Swift types through ``PostgresDecodable``. A column that is
/// SQL NULL throws from the non-nullable decode methods and resolves to
/// ``PostgresColumnValue/sqlNull`` from the nullable ones, so absence is always
/// an explicit decision at the call site rather than a silent optional.
public struct PostgresRow: Sendable {

    public let columns: [PostgresColumn]
    public let cells: [PostgresCell]

    public init(columns: [PostgresColumn], cells: [PostgresCell]) {
        self.columns = columns
        self.cells = cells
    }

    public func cell(at index: Int) throws(PostgresError) -> PostgresCell {
        guard index >= 0, index < cells.count else {
            throw PostgresError.columnIndexOutOfRange(index: index, columnCount: cells.count)
        }
        return cells[index]
    }

    public func index(ofColumn name: String) throws(PostgresError) -> Int {
        for (offset, column) in columns.enumerated() where column.name == name {
            return offset
        }
        throw PostgresError.columnNameNotFound(name: name)
    }

    public func cell(named name: String) throws(PostgresError) -> PostgresCell {
        try cell(at: index(ofColumn: name))
    }

    public func decode<Value: PostgresDecodable>(_ type: Value.Type, at index: Int) throws(PostgresError) -> Value {
        switch try cell(at: index) {
        case .sqlNull: throw PostgresError.columnIsNull(column: "index \(index)")
        case .bytes(let bytes): return try Value.decode(from: decodingValue(bytes, at: index))
        }
    }

    public func decode<Value: PostgresDecodable>(_ type: Value.Type, named name: String) throws(PostgresError) -> Value {
        try decode(type, at: index(ofColumn: name))
    }

    public func decodeNullable<Value: PostgresDecodable>(_ type: Value.Type, at index: Int) throws(PostgresError) -> PostgresColumnValue<Value> {
        switch try cell(at: index) {
        case .sqlNull: return .sqlNull
        case .bytes(let bytes): return .value(try Value.decode(from: decodingValue(bytes, at: index)))
        }
    }

    public func decodeNullable<Value: PostgresDecodable>(_ type: Value.Type, named name: String) throws(PostgresError) -> PostgresColumnValue<Value> {
        try decodeNullable(type, at: index(ofColumn: name))
    }

    /// Decodes a `json` or `jsonb` column into a `Decodable` value through
    /// Foundation's `JSONDecoder`. Throws ``PostgresError/columnIsNull(column:)``
    /// for a SQL NULL; use ``cell(at:)`` and check for NULL first when the column
    /// is nullable.
    public func decodeJSON<Value: Decodable>(_ type: Value.Type, at index: Int) throws(PostgresError) -> Value {
        switch try cell(at: index) {
        case .sqlNull: throw PostgresError.columnIsNull(column: "index \(index)")
        case .bytes(let bytes): return try PostgresJSONCoding.decode(type, from: decodingValue(bytes, at: index))
        }
    }

    public func decodeJSON<Value: Decodable>(_ type: Value.Type, named name: String) throws(PostgresError) -> Value {
        try decodeJSON(type, at: index(ofColumn: name))
    }

    /// Maps the whole row onto a `Decodable` value: a struct reads each property
    /// from the column of the same name, and a plain scalar reads the first
    /// column. Leaf types decode through their column decoders; a property whose
    /// type is itself a struct or collection is read from a JSON column.
    public func decode<Value: Decodable>(_ type: Value.Type) throws(PostgresError) -> Value {
        do {
            return try Value(from: PostgresRowDecoder(row: self))
        } catch let error as PostgresError {
            throw error
        } catch {
            throw PostgresError.typeDecodingFailed(type: "\(Value.self)", reason: String(describing: error))
        }
    }

    /// Decodes an array column into `[Element]`, requiring every element to be
    /// non-NULL. Use ``decodeNullableArray(_:at:)`` for an array that may contain
    /// NULL elements. Array columns are returned in binary on the parameterized
    /// query path.
    public func decodeArray<Element: PostgresDecodable>(_ type: Element.Type, at index: Int) throws(PostgresError) -> [Element] {
        var result: [Element] = []
        for element in try decodeNullableArray(type, at: index) {
            result.append(try Self.requireNonNull(element, at: index))
        }
        return result
    }

    public func decodeArray<Element: PostgresDecodable>(_ type: Element.Type, named name: String) throws(PostgresError) -> [Element] {
        try decodeArray(type, at: index(ofColumn: name))
    }

    public func decodeNullableArray<Element: PostgresDecodable>(_ type: Element.Type, at index: Int) throws(PostgresError) -> [PostgresColumnValue<Element>] {
        switch try cell(at: index) {
        case .sqlNull: throw PostgresError.columnIsNull(column: "index \(index)")
        case .bytes(let bytes): return try decodeArrayElements(type, bytes: bytes, at: index)
        }
    }

    public func decodeNullableArray<Element: PostgresDecodable>(_ type: Element.Type, named name: String) throws(PostgresError) -> [PostgresColumnValue<Element>] {
        try decodeNullableArray(type, at: index(ofColumn: name))
    }

    private func decodeArrayElements<Element: PostgresDecodable>(_ type: Element.Type, bytes: [UInt8], at index: Int) throws(PostgresError) -> [PostgresColumnValue<Element>] {
        let column = columns[index]
        let arrayValue = PostgresDecodingValue(bytes: bytes, format: column.format, dataTypeObjectID: column.dataTypeObjectID)
        return try Self.decodeElements(type, elements: PostgresArray.parse(arrayValue))
    }

    private static func decodeElements<Element: PostgresDecodable>(_ type: Element.Type, elements: PostgresArrayElements) throws(PostgresError) -> [PostgresColumnValue<Element>] {
        var result: [PostgresColumnValue<Element>] = []
        result.reserveCapacity(elements.cells.count)
        for cell in elements.cells {
            result.append(try decodeElement(type, cell: cell, elements: elements))
        }
        return result
    }

    private static func decodeElement<Element: PostgresDecodable>(_ type: Element.Type, cell: PostgresCell, elements: PostgresArrayElements) throws(PostgresError) -> PostgresColumnValue<Element> {
        switch cell {
        case .sqlNull: return .sqlNull
        case .bytes(let bytes): return .value(try Element.decode(from: PostgresDecodingValue(bytes: bytes, format: elements.format, dataTypeObjectID: elements.elementObjectID)))
        }
    }

    private static func requireNonNull<Element>(_ value: PostgresColumnValue<Element>, at index: Int) throws(PostgresError) -> Element {
        switch value {
        case .sqlNull: throw PostgresError.columnIsNull(column: "array element at column index \(index)")
        case .value(let element): return element
        }
    }

    private func decodingValue(_ bytes: [UInt8], at index: Int) -> PostgresDecodingValue {
        let column = columns[index]
        return PostgresDecodingValue(bytes: bytes, format: column.format, dataTypeObjectID: column.dataTypeObjectID)
    }
}
