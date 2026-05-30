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
import NIOCore

// Decoder for columns sent with `Kind == sparse`. The wire format is:
//
//   offsets stream:
//     repeat: UVarInt group_size_of_defaults_before_next_non_default
//     terminator: UVarInt (trailing_default_count | END_OF_GRANULE_FLAG)
//   nested values:
//     N values of the column's nested spec, where N = number of
//     non-default offset entries before the terminator
//
// END_OF_GRANULE_FLAG is the bit `1 << 62`. Per CH's serializeOffsets
// in `Serializations/SerializationSparse.cpp`, this bit is set on the
// final UVarInt of the offsets stream and its low 62 bits hold the
// count of trailing defaults after the last non-default entry. The
// row-count invariant the reader enforces:
//
//     sum(group_sizes) + non_default_count + trailing_defaults == totalRows
//
// where `non_default_count == offsets.count` and the cursor advances
// `group_size + 1` after each entry (the +1 covering the non-default
// row that follows the run of defaults).
//
// CH applies sparse only to primitive scalar types (numeric, Bool,
// String, FixedString, UUID, Date*, DateTime*, Decimal*, Enum*,
// IPv4/IPv6, Time*, Interval, BFloat16). It is never wrapped around
// composite serializations (Array, Tuple, Map, Nullable,
// LowCardinality), so this decoder rejects those at the boundary.
enum ClickHouseSparseColumnDecoder {

    private static let endOfGranuleFlag: UInt64 = 1 << 62

    // The sparse offsets stream encodes a runs-of-defaults format: a
    // single `END_OF_GRANULE_FLAG | totalRows` UVarInt (≤9 bytes wire)
    // can declare an arbitrary `totalRows`. Because trailing-default
    // rows have no per-row wire cost, the bytes-on-wire bound that
    // protects every other column codec is absent here, and a forged
    // `totalRows` would otherwise drive a `[T](repeating:count:)`
    // allocation up to `Int.max`. Cap output rows per sparse column
    // at 1 << 28 (~268 million) — well above any realistic
    // `max_block_size` while keeping per-column allocations bounded.
    static let maxRowsPerColumn: Int = 1 << 28

    static func decode(
        spec: ClickHouseColumnSpec,
        rows: Int,
        from buffer: inout ByteBuffer
    ) throws -> any ClickHouseColumn {
        guard rows <= Self.maxRowsPerColumn else {
            throw ClickHouseError.sparseRowCountExceedsLimit(
                rows: rows,
                limit: Self.maxRowsPerColumn
            )
        }
        let positions = try readPositions(totalRows: rows, from: &buffer)
        let nonDefaults = try ClickHouseColumnRegistry.decode(
            spec: spec,
            rows: positions.count,
            from: &buffer
        )
        return try scatter(
            spec: spec,
            totalRows: rows,
            positions: positions,
            nonDefaults: nonDefaults
        )
    }

    private static func readPositions(totalRows: Int, from buffer: inout ByteBuffer) throws -> [Int] {
        var positions: [Int] = []
        var cursor: UInt64 = 0
        let total = UInt64(totalRows)
        while true {
            let raw = try buffer.readClickHouseUVarInt()
            if try processEndMarker(raw: raw, cursor: cursor, total: total, totalRows: totalRows) {
                return positions
            }
            cursor &+= raw
            try requirePositionInRange(cursor: cursor, total: total, totalRows: totalRows)
            positions.append(Int(cursor))
            cursor &+= 1
        }
    }

    private static func processEndMarker(raw: UInt64, cursor: UInt64, total: UInt64, totalRows: Int) throws -> Bool {
        guard (raw & endOfGranuleFlag) != 0 else { return false }
        let trailing = raw & ~endOfGranuleFlag
        guard cursor &+ trailing == total else {
            throw ClickHouseError.sparseOffsetExceedsRowCount(
                offset: Int(clamping: cursor &+ trailing),
                rows: totalRows
            )
        }
        return true
    }

    private static func requirePositionInRange(cursor: UInt64, total: UInt64, totalRows: Int) throws {
        guard cursor < total else {
            throw ClickHouseError.sparseOffsetExceedsRowCount(
                offset: Int(clamping: cursor),
                rows: totalRows
            )
        }
    }

    private static func scatter(
        spec: ClickHouseColumnSpec,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> any ClickHouseColumn {
        switch spec {
        case .int8:
            return try scatterInteger(Int8.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .int16:
            return try scatterInteger(Int16.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .int32, .date32, .decimal32, .time:
            return try scatterInteger(Int32.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .int64, .dateTime64, .decimal64, .time64, .interval:
            return try scatterInteger(Int64.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .int128, .decimal128:
            return try scatterInteger(Int128.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .uint8:
            return try scatterInteger(UInt8.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .uint16, .date:
            return try scatterInteger(UInt16.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .uint32, .dateTime, .ipv4:
            return try scatterInteger(UInt32.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .uint64:
            return try scatterInteger(UInt64.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .uint128:
            return try scatterInteger(UInt128.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .enum8:
            return try scatterInteger(Int8.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .enum16:
            return try scatterInteger(Int16.self, spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .float32:
            return try scatterFloat32(spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .float64:
            return try scatterFloat64(spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .bool:
            return try scatterBool(spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .string, .json:
            return try scatterString(spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .uuid:
            return try scatterUUID(spec: spec, totalRows: totalRows, positions: positions, nonDefaults: nonDefaults)
        case .fixedString(let length):
            return try scatterFixedString(
                spec: spec,
                length: length,
                totalRows: totalRows,
                positions: positions,
                nonDefaults: nonDefaults
            )
        case .ipv6:
            return try scatterFixedString(
                spec: spec,
                length: 16,
                totalRows: totalRows,
                positions: positions,
                nonDefaults: nonDefaults
            )
        case .int256, .uint256, .decimal256, .bfloat16, .nothing,
             .array, .nullable, .tuple, .map, .lowCardinality:
            throw ClickHouseError.sparseSerializationOnUnsupportedSpec(typeName: spec.typeName)
        }
    }

    private static func scatterInteger<T: FixedWidthInteger & Sendable>(
        _: T.Type,
        spec: ClickHouseColumnSpec,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> ClickHouseFixedWidthIntegerColumn<T> {
        guard let typed = nonDefaults as? ClickHouseFixedWidthIntegerColumn<T> else {
            throw ClickHouseError.sparseScatterTypeMismatch(spec: spec)
        }
        var values = [T](repeating: 0, count: totalRows)
        for (index, position) in positions.enumerated() {
            values[position] = typed.values[index]
        }
        return .init(spec: spec, values: values)
    }

    private static func scatterFloat32(
        spec: ClickHouseColumnSpec,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> ClickHouseFloat32Column {
        guard let typed = nonDefaults as? ClickHouseFloat32Column else {
            throw ClickHouseError.sparseScatterTypeMismatch(spec: spec)
        }
        var values = [Float32](repeating: 0, count: totalRows)
        for (index, position) in positions.enumerated() {
            values[position] = typed.values[index]
        }
        return .init(values: values)
    }

    private static func scatterFloat64(
        spec: ClickHouseColumnSpec,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> ClickHouseFloat64Column {
        guard let typed = nonDefaults as? ClickHouseFloat64Column else {
            throw ClickHouseError.sparseScatterTypeMismatch(spec: spec)
        }
        var values = [Float64](repeating: 0, count: totalRows)
        for (index, position) in positions.enumerated() {
            values[position] = typed.values[index]
        }
        return .init(values: values)
    }

    private static func scatterBool(
        spec: ClickHouseColumnSpec,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> ClickHouseBoolColumn {
        guard let typed = nonDefaults as? ClickHouseBoolColumn else {
            throw ClickHouseError.sparseScatterTypeMismatch(spec: spec)
        }
        var values = [Bool](repeating: false, count: totalRows)
        for (index, position) in positions.enumerated() {
            values[position] = typed.values[index]
        }
        return .init(values: values)
    }

    private static func scatterString(
        spec: ClickHouseColumnSpec,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> ClickHouseStringColumn {
        guard let typed = nonDefaults as? ClickHouseStringColumn else {
            throw ClickHouseError.sparseScatterTypeMismatch(spec: spec)
        }
        var values = [String](repeating: "", count: totalRows)
        for (index, position) in positions.enumerated() {
            values[position] = typed.values[index]
        }
        return .init(spec: spec, values: values)
    }

    private static func scatterUUID(
        spec: ClickHouseColumnSpec,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> ClickHouseUUIDColumn {
        guard let typed = nonDefaults as? ClickHouseUUIDColumn else {
            throw ClickHouseError.sparseScatterTypeMismatch(spec: spec)
        }
        let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var values = [UUID](repeating: zeroUUID, count: totalRows)
        for (index, position) in positions.enumerated() {
            values[position] = typed.values[index]
        }
        return .init(values: values)
    }

    private static func scatterFixedString(
        spec: ClickHouseColumnSpec,
        length: Int,
        totalRows: Int,
        positions: [Int],
        nonDefaults: any ClickHouseColumn
    ) throws -> ClickHouseFixedStringColumn {
        guard let typed = nonDefaults as? ClickHouseFixedStringColumn else {
            throw ClickHouseError.sparseScatterTypeMismatch(spec: spec)
        }
        let zero = Data(repeating: 0, count: length)
        var values = [Data](repeating: zero, count: totalRows)
        for (index, position) in positions.enumerated() {
            values[position] = typed.values[index]
        }
        return .init(spec: spec, length: length, values: values)
    }

}
