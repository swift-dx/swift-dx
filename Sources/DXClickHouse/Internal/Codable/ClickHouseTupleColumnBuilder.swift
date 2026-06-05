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

// Bridges the encoder's row-major Tuple accumulation (per row, per
// element raw value bytes) into the column-major `[ClickHouseTypedColumn]`
// that the wire writer and the decoder share. One inner column per tuple
// element, each carrying every row, mirroring the ClickHouse Tuple wire
// layout where each element column is serialized in full sequentially.
enum ClickHouseTupleColumnBuilder {

    static func columns(rows: [[[UInt8]]], elements: [ClickHouseArrayElementType]) -> [ClickHouseTypedColumn] {
        let perElement = transpose(rows: rows, elementCount: elements.count)
        var built: [ClickHouseTypedColumn] = []
        built.reserveCapacity(elements.count)
        for position in elements.indices {
            built.append(column(of: elements[position], rawValues: perElement[position]))
        }
        return built
    }

    private static func transpose(rows: [[[UInt8]]], elementCount: Int) -> [[[UInt8]]] {
        var perElement: [[[UInt8]]] = Array(repeating: [], count: elementCount)
        for position in perElement.indices { perElement[position].reserveCapacity(rows.count) }
        for row in rows {
            appendRow(row, into: &perElement)
        }
        return perElement
    }

    private static func appendRow(_ row: [[UInt8]], into perElement: inout [[[UInt8]]]) {
        for position in perElement.indices {
            perElement[position].append(row[position])
        }
    }

    static func rawElementBytes(columns: [ClickHouseTypedColumn], rowIndex: Int) -> [[UInt8]] {
        var values: [[UInt8]] = []
        values.reserveCapacity(columns.count)
        for column in columns {
            values.append(rawValue(of: column, rowIndex: rowIndex))
        }
        return values
    }

    static func elementTypes(of columns: [ClickHouseTypedColumn]) throws(ClickHouseError) -> [ClickHouseArrayElementType] {
        var types: [ClickHouseArrayElementType] = []
        types.reserveCapacity(columns.count)
        for column in columns {
            types.append(try elementType(of: column))
        }
        return types
    }

    private static func column(of element: ClickHouseArrayElementType, rawValues: [[UInt8]]) -> ClickHouseTypedColumn {
        switch element {
        case .string: return .string(rawValues)
        case .fixedString(let length): return .fixedString(rawValues, length: length)
        case .bool: return .bool(rawValues.map { scalarByte($0) != 0 })
        case .int8: return .int8(rawValues.map { Int8(bitPattern: scalarByte($0)) })
        case .uint8: return .uint8(rawValues.map { scalarByte($0) })
        case .int16: return .int16(rawValues.map { Int16(bitPattern: scalar($0)) })
        case .uint16: return .uint16(rawValues.map { scalar($0) })
        case .int32: return .int32(rawValues.map { Int32(bitPattern: scalar($0)) })
        case .uint32: return .uint32(rawValues.map { scalar($0) })
        case .int64: return .int64(rawValues.map { Int64(bitPattern: scalar($0)) })
        case .uint64: return .uint64(rawValues.map { scalar($0) })
        case .float32: return .float32(rawValues.map { Float(bitPattern: scalar($0)) })
        case .float64: return .float64(rawValues.map { Double(bitPattern: scalar($0)) })
        case .dateTime: return .dateTime(rawValues.map { Date(timeIntervalSince1970: TimeInterval(scalar($0) as UInt32)) })
        case .date: return .date(rawValues.map { scalar($0) as UInt16 })
        case .date32: return .date32(rawValues.map { Int32(bitPattern: scalar($0)) })
        case .dateTime64(let precision): return .dateTime64(rawValues.map { Int64(bitPattern: scalar($0)) }, precision: precision)
        case .decimal(let precision, let scale): return .decimal(rawValues.map { ClickHouseDecimal(littleEndianBytes: $0, precision: precision, scale: scale) }, precision: precision, scale: scale)
        case .enum8(let mapping): return .enum8(rawValues.map { Int8(bitPattern: scalarByte($0)) }, mapping: mapping)
        case .enum16(let mapping): return .enum16(rawValues.map { Int16(bitPattern: scalar($0)) }, mapping: mapping)
        case .uuid: return .uuid(rawValues.map { ClickHouseUUIDWire.uuid(fromWire: $0) })
        case .ipv4: return .ipv4(rawValues.map { scalar($0) })
        case .ipv6: return .ipv6(rawValues)
        case .int128: return .int128(rawValues.map { scalar($0) })
        case .uint128: return .uint128(rawValues.map { scalar($0) })
        case .int256: return .int256(rawValues.map { ClickHouseInt256(littleEndianBytes: $0) })
        case .uint256: return .uint256(rawValues.map { ClickHouseUInt256(littleEndianBytes: $0) })
        }
    }

    private static func rawValue(of column: ClickHouseTypedColumn, rowIndex: Int) -> [UInt8] {
        switch column {
        case .string(let values): return values[rowIndex]
        case .fixedString(let values, _): return values[rowIndex]
        case .bool(let values): return [values[rowIndex] ? 1 : 0]
        case .int8(let values): return [UInt8(bitPattern: values[rowIndex])]
        case .uint8(let values): return [values[rowIndex]]
        case .int16(let values): return littleEndianBytes(UInt16(bitPattern: values[rowIndex]))
        case .uint16(let values): return littleEndianBytes(values[rowIndex])
        case .int32(let values): return littleEndianBytes(UInt32(bitPattern: values[rowIndex]))
        case .uint32(let values): return littleEndianBytes(values[rowIndex])
        case .int64(let values): return littleEndianBytes(UInt64(bitPattern: values[rowIndex]))
        case .uint64(let values): return littleEndianBytes(values[rowIndex])
        case .float32(let values): return littleEndianBytes(values[rowIndex].bitPattern)
        case .float64(let values): return littleEndianBytes(values[rowIndex].bitPattern)
        default: return []
        }
    }

    private static func elementType(of column: ClickHouseTypedColumn) throws(ClickHouseError) -> ClickHouseArrayElementType {
        switch column {
        case .string: return .string
        case .fixedString(_, let length): return .fixedString(length: length)
        case .bool: return .bool
        case .int8: return .int8
        case .uint8: return .uint8
        case .int16: return .int16
        case .uint16: return .uint16
        case .int32: return .int32
        case .uint32: return .uint32
        case .int64: return .int64
        case .uint64: return .uint64
        case .float32: return .float32
        case .float64: return .float64
        default:
            throw .protocolError(stage: "decoder.tuple", message: "Tuple contains an element type ClickHouseTuple cannot represent (supported: String, FixedString, Bool, Int8/16/32/64, UInt8/16/32/64, Float32, Float64); select the tuple elements as separate columns")
        }
    }

    private static func scalar<T: FixedWidthInteger>(_ bytes: [UInt8]) -> T {
        var value: T = 0
        let width = MemoryLayout<T>.size
        for byteIndex in 0..<min(width, bytes.count) {
            value |= T(bytes[byteIndex]) << (8 * byteIndex)
        }
        return value
    }

    private static func scalarByte(_ bytes: [UInt8]) -> UInt8 {
        bytes.isEmpty ? 0 : bytes[0]
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }
}
