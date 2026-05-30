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

// Converts one row of a `ClickHouseBlock` into a JSON object suitable
// for `JSONDecoder`. Used by `ClickHouseClient.decodedRows` to bridge
// the native protocol's columnar Data blocks to the public typed-row
// API.
//
// The native protocol always returns columnar Data blocks regardless
// of any `FORMAT` clause in the SQL — so the only stable way to expose
// a "rows of T" view is to serialize the column slice ourselves.
//
// Serialization goes through `JSONEncoder` (not `JSONSerialization`)
// because the latter uses Foundation's number formatter, which on
// Linux truncates `Double` to ~15 significant digits and drops one
// ULP of precision on most random Float64 values. `JSONEncoder` writes
// each `Double` via Swift's `String(_:Double)` which is the shortest
// round-trip-safe representation (Grisu/Ryu) on every supported
// platform, preserving bit-exact equality across the encode/decode
// boundary.
//
// Value conventions (chosen for round-trippability with default
// `JSONDecoder`, not human readability):
//
//   Bool                     true / false
//   Int8...Int32, UInt8/16   JSON number (Int)
//   Int64, UInt32            JSON number (Int64)
//   UInt64                   JSON number (UInt64)
//   Int128, UInt128          JSON string (out of safe-integer range)
//   Float32, Float64         JSON number (Double)
//   String, JSON             JSON string
//   FixedString              UTF-8 if valid; base64 otherwise
//   UUID                     JSON string, lowercase, dashed
//   Date, Date32             JSON number (raw days from epoch)
//   DateTime                 JSON number (raw seconds from epoch)
//   DateTime64               JSON number (raw ticks; precision in spec)
//   IPv4                     JSON number (raw UInt32)
//   IPv6                     JSON string (UTF-8 if valid; base64 otherwise)
//   Decimal32, Decimal64     JSON number (raw integer; scale in spec)
//   Decimal128               JSON string (raw integer)
//   Time, Time64, Interval   JSON number
//   Enum8, Enum16            JSON number (raw code)
//   Nullable(T)              null or T's representation
//   Array(T)                 JSON array of T's representations
//   Tuple(...)               JSON array of element representations
//   Map(K, V)                JSON object (keys stringified)
//   LowCardinality(T)        T's representation at the dictionary index
//
// Specs not yet bridged (Int256, UInt256, Decimal256, BFloat16,
// Nothing) raise `unsupportedJSONColumnType`. Composite specs recurse
// through `value(of:row:)` so callers see the same conventions all the
// way down.
enum ClickHouseRowJSONEncoder {

    static func encode(block: ClickHouseBlock, rowIndex: Int) throws -> Data {
        guard rowIndex >= 0, rowIndex < block.rowCount else {
            throw ClickHouseError.rowIndexOutOfRange(rowIndex: rowIndex, rowCount: block.rowCount)
        }
        var dict: [String: JSONValue] = [:]
        dict.reserveCapacity(block.columns.count)
        for namedColumn in block.columns {
            dict[namedColumn.name] = try value(of: namedColumn.column, row: rowIndex)
        }
        return try JSONEncoder().encode(dict)
    }

    private static func value(of column: any ClickHouseColumn, row: Int) throws -> JSONValue {
        let primitive = try primitiveValue(of: column, row: row)
        switch primitive {
        case .matched(let json): return json
        case .notPrimitive: return try compositeValue(of: column, row: row)
        }
    }

    private enum PrimitiveJSONMatch {

        case matched(JSONValue)
        case notPrimitive

    }

    private static func primitiveValue(of column: any ClickHouseColumn, row: Int) throws -> PrimitiveJSONMatch {
        switch column {
        case let c as ClickHouseBoolColumn:
            return .matched(.bool(c.values[row]))
        case let c as ClickHouseFixedWidthIntegerColumn<Int8>:
            return .matched(.int64(Int64(c.values[row])))
        case let c as ClickHouseFixedWidthIntegerColumn<Int16>:
            return .matched(.int64(Int64(c.values[row])))
        case let c as ClickHouseFixedWidthIntegerColumn<Int32>:
            return .matched(.int64(Int64(c.values[row])))
        case let c as ClickHouseFixedWidthIntegerColumn<Int64>:
            return .matched(.int64(c.values[row]))
        case let c as ClickHouseFixedWidthIntegerColumn<Int128>:
            return .matched(.string(c.values[row].description))
        case let c as ClickHouseFixedWidthIntegerColumn<UInt8>:
            return .matched(.int64(Int64(c.values[row])))
        case let c as ClickHouseFixedWidthIntegerColumn<UInt16>:
            return .matched(.int64(Int64(c.values[row])))
        case let c as ClickHouseFixedWidthIntegerColumn<UInt32>:
            return .matched(.int64(Int64(c.values[row])))
        case let c as ClickHouseFixedWidthIntegerColumn<UInt64>:
            return .matched(.uint64(c.values[row]))
        case let c as ClickHouseFixedWidthIntegerColumn<UInt128>:
            return .matched(.string(c.values[row].description))
        case let c as ClickHouseFloat32Column:
            return .matched(.double(try Self.requireFinite(Double(c.values[row]), row: row)))
        case let c as ClickHouseFloat64Column:
            return .matched(.double(try Self.requireFinite(c.values[row], row: row)))
        case let c as ClickHouseStringColumn:
            return .matched(.string(c.values[row]))
        case let c as ClickHouseFixedStringColumn:
            let bytes = c.values[row]
            let asString = String(data: bytes, encoding: .utf8) ?? bytes.base64EncodedString()
            return .matched(.string(asString))
        case let c as ClickHouseUUIDColumn:
            return .matched(.string(c.values[row].uuidString.lowercased()))
        default:
            return .notPrimitive
        }
    }

    private static func compositeValue(of column: any ClickHouseColumn, row: Int) throws -> JSONValue {
        switch column {
        case let c as ClickHouseNullableColumn: return try nullableValue(of: c, row: row)
        case let c as ClickHouseArrayColumn: return .array(try arraySlice(of: c, row: row))
        case let c as ClickHouseTupleColumn: return .array(try tupleElements(of: c, row: row))
        case let c as ClickHouseLowCardinalityColumn: return try lowCardinalityValue(of: c, row: row)
        case let c as ClickHouseMapColumn: return .object(try mapEntries(of: c, row: row))
        default: throw ClickHouseError.unsupportedJSONColumnType(typeName: column.spec.typeName)
        }
    }

    private static func nullableValue(of column: ClickHouseNullableColumn, row: Int) throws -> JSONValue {
        if column.nullMask[row] { return .null }
        return try value(of: column.inner, row: row)
    }

    private static func lowCardinalityValue(of column: ClickHouseLowCardinalityColumn, row: Int) throws -> JSONValue {
        let rawIndex = column.indices[row]
        let index = try requireDictionaryIndex(rawIndex: rawIndex, dictionarySize: column.dictionary.rowCount)
        return try value(of: column.dictionary, row: index)
    }

    private static func requireDictionaryIndex(rawIndex: UInt64, dictionarySize: Int) throws -> Int {
        guard dictionaryIndexInRange(rawIndex: rawIndex, dictionarySize: dictionarySize) else {
            throw ClickHouseError.lowCardinalityDictionaryIndexOutOfRange(
                index: Int(clamping: rawIndex),
                dictionarySize: dictionarySize
            )
        }
        return Int(rawIndex)
    }

    private static func dictionaryIndexInRange(rawIndex: UInt64, dictionarySize: Int) -> Bool {
        rawIndex < UInt64(dictionarySize)
    }

    private static func arraySlice(of column: ClickHouseArrayColumn, row: Int) throws -> [JSONValue] {
        let start = row == 0 ? 0 : Int(column.offsets[row - 1])
        let end = Int(column.offsets[row])
        var items: [JSONValue] = []
        items.reserveCapacity(end - start)
        for innerRow in start..<end {
            items.append(try value(of: column.inner, row: innerRow))
        }
        return items
    }

    private static func tupleElements(of column: ClickHouseTupleColumn, row: Int) throws -> [JSONValue] {
        var items: [JSONValue] = []
        items.reserveCapacity(column.elements.count)
        for element in column.elements {
            items.append(try value(of: element, row: row))
        }
        return items
    }

    private static func mapEntries(of column: ClickHouseMapColumn, row: Int) throws -> [String: JSONValue] {
        let start = row == 0 ? 0 : Int(column.offsets[row - 1])
        let end = Int(column.offsets[row])
        var dict: [String: JSONValue] = [:]
        dict.reserveCapacity(end - start)
        for innerRow in start..<end {
            let key = try keyString(of: column.keys, row: innerRow)
            dict[key] = try value(of: column.values, row: innerRow)
        }
        return dict
    }

    // JSON has no representation for NaN or ±Infinity; `JSONEncoder`
    // throws an opaque `EncodingError` when one shows up. Detect
    // non-finite values upfront and surface a typed error pointing at
    // the row, so the user knows the cause is data shape (e.g., a
    // SELECT producing `0/0`) and can filter server-side or use the
    // lower-level `selectColumns` API which preserves the bit-pattern.
    private static func requireFinite(_ value: Double, row: Int) throws -> Double {
        guard value.isFinite else {
            throw ClickHouseError.nonFiniteFloatInJSONOutput(
                textualValue: value.description,
                row: row
            )
        }
        return value
    }

    private static func keyString(of column: any ClickHouseColumn, row: Int) throws -> String {
        let raw = try value(of: column, row: row)
        switch raw {
        case .string(let s): return s
        case .int64(let i): return String(i)
        case .uint64(let u): return String(u)
        case .bool(let b): return b ? "true" : "false"
        case .double(let d): return String(d)
        default:
            throw ClickHouseError.unsupportedJSONColumnType(typeName: "Map key of \(column.spec.typeName)")
        }
    }

}

// Type-erased JSON value used to bridge the heterogeneous column
// stream into a single `Encodable` tree. `JSONEncoder` then handles
// serialization of every leaf with platform-correct number
// formatting — in particular, `Double` is written via Swift's
// shortest round-trip-safe representation rather than Foundation's
// truncating formatter.
private enum JSONValue: Encodable {

    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .int64(let v):
            try container.encode(v)
        case .uint64(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }

}
