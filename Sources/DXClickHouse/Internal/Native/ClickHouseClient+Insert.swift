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
import Instrumentation
import NIOCore
import Tracing

// Column-major INSERT path. Two public entry points:
//
//   - `insert(into:columns:)` for one block of columns
//   - `insert(into:blocks:)` for a pre-materialized array of blocks
//
// (The streaming `insert(into:blockProvider:)` lives in the
// `+InsertStream` extension and is the right choice when blocks are
// produced lazily, e.g., from an ETL cursor.)
//
// Multi-block inserts validate cross-block shape (column names + spec
// equality) BEFORE any wire send, so a schema mismatch surfaces at
// the call site rather than after the server has accepted block 0
// and rejected block N.
//
// `toInternalColumn` is the heart of this file: a 100-case switch
// that lowers each `ClickHouseColumnEntry.Values` variant to the
// concrete typed column the wire layer expects. Date/Time variants
// validate their input range here (UInt16 days for Date, UInt32
// seconds for DateTime, etc.), surfacing `dateValueOutOfRange` at
// encode time rather than letting the server reject a wraparound.
extension ClickHouseClient {

    public func insert(into table: String, columns: [ClickHouseColumnEntry], settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) {
        try await ClickHouseError.bridge {
            try await InstrumentationSystem.tracer.withSpan(
                "clickhouse.insert.columns", context: .current ?? .topLevel, ofKind: .client
            ) { span in
                span.attributes["db.system.name"] = "clickhouse"
                span.attributes["db.operation.name"] = "INSERT"
                span.attributes["db.collection.name"] = table
                try await writeColumns(into: table, columns: columns, settings: settings, parameters: parameters)
            }
        }
    }

    // Column-major INSERT of a single block, without the operation
    // span. The traced `insert(into:columns:)` and the typed
    // `insert(into:rows:)` both delegate here, so a typed insert emits
    // one `clickhouse.insert` span instead of nesting an
    // `insert.columns` span inside it.
    func writeColumns(into table: String, columns: [ClickHouseColumnEntry], settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws {
        // No-op for an empty input: the natural interpretation of
        // "insert nothing" is do nothing, no wire round-trip. Symmetric
        // with `insert(into:blocks: [])` which already short-circuits at
        // the cursor level. Without this guard the call would reach
        // `makeBlock` and throw `blockHasNoColumns` — confusing for ETL
        // pipelines that legitimately receive empty batches and propagate
        // up through `ClickHouse.insert(into:rows: [])`.
        guard !columns.isEmpty else { return }
        let block = try Self.makeBlock(from: columns)
        // CH 25.x parser requires the FORMAT clause explicitly; older
        // servers tolerated a bare `INSERT INTO t`. `FORMAT Native`
        // tells the server the upcoming Data packets are in the native
        // wire format (which the client always sends). The explicit
        // column list is required when the caller writes a subset of
        // the table's columns — otherwise the server's sample block
        // declares every destination column and the client's narrower
        // block fails the count check with `insertColumnCountMismatch`.
        let columnList = Self.makeColumnListSQL(columns)
        try await insert("INSERT INTO \(table) \(columnList) FORMAT Native", blocks: [block], settings: settings, parameters: parameters)
    }

    // Multi-block INSERT for large datasets: each `[ClickHouseColumnEntry]`
    // becomes one Data packet on the wire, sent in sequence under the same
    // Query. All blocks must share the same column structure (names + types);
    // the server rejects the second block with a structure-mismatch error
    // otherwise. Memory usage peaks at one block at a time rather than the
    // sum of all rows.
    public func insert(
        into table: String,
        blocks: [[ClickHouseColumnEntry]],
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = []
    ) async throws(ClickHouseError) {
        // Symmetric with the single-block path: empty input is a no-op,
        // not a wire round-trip with a zero-row INSERT statement. ETL
        // pipelines that hand the multi-block API an empty array of
        // batches expect "do nothing" behavior; pre-fix we acquired a
        // connection, sent Query + schema preamble + terminator, and
        // waited for EndOfStream just to issue an INSERT that produced
        // zero rows server-side. Save the round-trip and the pool slot.
        guard !blocks.isEmpty else { return }
        try await ClickHouseError.bridge {
            let internalBlocks = try blocks.map { try Self.makeBlock(from: $0) }
            try Self.validateBlockStructure(internalBlocks)
            // All blocks share the same column structure (enforced by
            // `validateBlockStructure`), so the column list from the first
            // block applies to every subsequent block. See the single-block
            // path above for why the list is required.
            let columnList = Self.makeColumnListSQL(blocks[0])
            try await insert("INSERT INTO \(table) \(columnList) FORMAT Native", blocks: internalBlocks, settings: settings, parameters: parameters)
        }
    }

    static func makeColumnListSQL(_ columns: [ClickHouseColumnEntry]) -> String {
        // Backtick-quote every identifier. CH identifiers may contain
        // dots (Nested column projection like `Events.Timestamp`) and
        // other non-identifier characters that are only legal inside
        // backticks. Backticks themselves are not valid inside CH
        // identifiers so escaping is unnecessary.
        let quoted = columns.map { "`\($0.name)`" }.joined(separator: ", ")
        return "(\(quoted))"
    }

    static func makeBlock(from columns: [ClickHouseColumnEntry]) throws -> ClickHouseBlock {
        // Reject empty columns: a 0-column block is wire-equivalent to
        // the data-phase terminator. Sending it as data would cause the
        // server to interpret the FIRST data packet as "no more data"
        // and reject the explicit terminator that follows as an extra
        // unexpected packet. Callers that want a no-op INSERT should
        // omit the call entirely; callers that want a row-less but
        // schema-bearing block should pass a column with empty values
        // (e.g., `[ColumnEntry(name: "v", values: .int32([]))]`).
        guard !columns.isEmpty else {
            throw ClickHouseError.blockHasNoColumns
        }
        let namedColumns = try columns.map { entry in
            ClickHouseBlock.NamedColumn(name: entry.name, column: try Self.toInternalColumn(entry.values))
        }
        return ClickHouseBlock(blockInfo: .init(), columns: namedColumns)
    }

    // Cross-block consistency check before any wire send. Catches schema
    // drift (different column names, counts, or types between blocks) at
    // the call site rather than after the server has already received a
    // mismatched block. Single-block and empty-blocks inputs are no-ops.
    static func validateBlockStructure(_ blocks: [ClickHouseBlock]) throws {
        guard let first = blocks.first, blocks.count > 1 else { return }
        let firstShape = first.columns.map { ($0.name, $0.column.spec) }
        for blockIndex in 1..<blocks.count {
            let shape = blocks[blockIndex].columns.map { ($0.name, $0.column.spec) }
            try compareShapes(blockIndex: blockIndex, expected: firstShape, actual: shape)
        }
    }

    static func compareShapes(
        blockIndex: Int,
        expected: [(String, ClickHouseColumnSpec)],
        actual: [(String, ClickHouseColumnSpec)]
    ) throws {
        guard expected.count == actual.count else {
            throw ClickHouseError.multiBlockStructureMismatch(
                blockIndex: blockIndex,
                message: "expected \(expected.count) columns, got \(actual.count)"
            )
        }
        for columnIndex in expected.indices {
            try compareColumnAt(blockIndex: blockIndex, columnIndex: columnIndex, expected: expected[columnIndex], actual: actual[columnIndex])
        }
    }

    private static func compareColumnAt(
        blockIndex: Int,
        columnIndex: Int,
        expected: (String, ClickHouseColumnSpec),
        actual: (String, ClickHouseColumnSpec)
    ) throws {
        if expected.0 != actual.0 {
            throw ClickHouseError.multiBlockStructureMismatch(
                blockIndex: blockIndex,
                message: "column \(columnIndex) name mismatch: expected '\(expected.0)', got '\(actual.0)'"
            )
        }
        if expected.1 != actual.1 {
            throw ClickHouseError.multiBlockStructureMismatch(
                blockIndex: blockIndex,
                message: "column '\(expected.0)' type mismatch: expected \(expected.1.typeName), got \(actual.1.typeName)"
            )
        }
    }

    private static let secondsPerDay: Double = 86_400

    private static let dateTime64Scales: [Double] = [
        1, 10, 100, 1_000, 10_000, 100_000,
        1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
    ]

    // Divisor that converts a `ClickHouseNanoseconds.rawValue` (always
    // ns) into the column-side ticks at `precision`. For precision 9
    // the divisor is 1 (no shift); for precision 0 it is 10⁹ (truncate
    // to whole seconds).
    static func nanosecondsToColumnDivisor(precision: Int) -> Int64 {
        let exponent = max(0, 9 - precision)
        var result: Int64 = 1
        for _ in 0..<exponent { result *= 10 }
        return result
    }

    static func toInternalColumn(_ input: ClickHouseColumnEntry.Values) throws -> any ClickHouseColumn {
        switch input {
        case .int8(let values): return ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: values)
        case .int16(let values): return ClickHouseFixedWidthIntegerColumn<Int16>(spec: .int16, values: values)
        case .int32(let values): return ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values)
        case .int64(let values): return ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: values)
        case .int128(let values): return ClickHouseFixedWidthIntegerColumn<Int128>(spec: .int128, values: values)
        case .uint8(let values): return ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: values)
        case .uint16(let values): return ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .uint16, values: values)
        case .uint32(let values): return ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .uint32, values: values)
        case .uint64(let values): return ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: values)
        case .uint128(let values): return ClickHouseFixedWidthIntegerColumn<UInt128>(spec: .uint128, values: values)
        case .float32(let values): return ClickHouseFloat32Column(values: values)
        case .float64(let values): return ClickHouseFloat64Column(values: values)
        case .string(let values): return ClickHouseStringColumn(values: values)
        case .bool(let values): return ClickHouseBoolColumn(values: values)
        case .uuid(let values): return ClickHouseUUIDColumn(values: values)
        case .date(let dates): return try toDateColumn(dates: dates)
        case .date32(let dates): return try toDate32Column(dates: dates)
        case .dateTime(let dates): return try toDateTimeColumn(dates: dates)
        case .dateTime64(let dates, let precision): return try toDateTime64Column(dates: dates, precision: precision)
        case .fixedString(let length, let datas): return try toFixedStringColumn(length: length, datas: datas)
        case .arrayOfString(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .string) {
                ClickHouseStringColumn(values: $0)
            }
        case .arrayOfInt32(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .int32) {
                ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: $0)
            }
        case .arrayOfInt64(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .int64) {
                ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: $0)
            }
        case .arrayOfUInt32(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .uint32) {
                ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .uint32, values: $0)
            }
        case .arrayOfUInt64(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .uint64) {
                ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: $0)
            }
        case .nullableString(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: "", innerSpec: .string) {
                ClickHouseStringColumn(values: $0)
            }
        case .nullableInt32(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .int32) {
                ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: $0)
            }
        case .nullableInt64(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .int64) {
                ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: $0)
            }
        case .nullableUInt32(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .uint32) {
                ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .uint32, values: $0)
            }
        case .nullableUInt64(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .uint64) {
                ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: $0)
            }
        case .mapStringString(let dicts):
            return Self.makeMapColumn(
                dicts: dicts,
                keySpec: .string,
                valueSpec: .string,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseStringColumn(values: $0) }
            )
        case .ipv4(let values): return ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .ipv4, values: values)
        case .ipv6(let datas): return try toIPv6Column(datas: datas)
        case .decimal32(let values, let scale): return try toDecimal32Column(values: values, scale: scale)
        case .decimal64(let values, let scale): return try toDecimal64Column(values: values, scale: scale)
        case .decimal128(let values, let scale): return try toDecimal128Column(values: values, scale: scale)
        case .nullableUUID(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: UUID(), innerSpec: .uuid) {
                ClickHouseUUIDColumn(values: $0)
            }
        case .nullableDate(let optionals): return try toNullableDateColumn(nullables: optionals)
        case .nullableDateTime(let optionals): return try toNullableDateTimeColumn(nullables: optionals)
        case .nullableBool(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: false, innerSpec: .bool) {
                ClickHouseBoolColumn(values: $0)
            }
        case .arrayOfUUID(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .uuid) {
                ClickHouseUUIDColumn(values: $0)
            }
        case .arrayOfBool(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .bool) {
                ClickHouseBoolColumn(values: $0)
            }
        case .mapStringInt32(let dicts):
            return makeMapColumn(
                dicts: dicts,
                keySpec: .string,
                valueSpec: .int32,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: $0) }
            )
        case .mapStringInt64(let dicts):
            return makeMapColumn(
                dicts: dicts,
                keySpec: .string,
                valueSpec: .int64,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: $0) }
            )
        case .arrayOfFloat32(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .float32) {
                ClickHouseFloat32Column(values: $0)
            }
        case .arrayOfFloat64(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .float64) {
                ClickHouseFloat64Column(values: $0)
            }
        case .arrayOfDate(let arrays): return try toArrayOfDateColumn(arrays: arrays)
        case .arrayOfDateTime(let arrays): return try toArrayOfDateTimeColumn(arrays: arrays)
        case .nullableFloat64(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .float64) {
                ClickHouseFloat64Column(values: $0)
            }
        case .tupleStringString(let pairs): return toTupleStringStringColumn(pairs: pairs)
        case .tupleStringInt32(let pairs): return toTupleStringInt32Column(pairs: pairs)
        case .tupleStringInt64(let pairs): return toTupleStringInt64Column(pairs: pairs)
        case .tupleFloat64Float64(let pairs): return toTupleFloat64Float64Column(pairs: pairs)
        case .time(let values): return ClickHouseFixedWidthIntegerColumn<Int32>(spec: .time, values: values)
        case .time64(let values, let precision): return try toTime64Column(values: values, precision: precision)
        case .interval(let kind, let values): return ClickHouseFixedWidthIntegerColumn<Int64>(spec: .interval(kind: kind), values: values)
        case .int256(let values): return ClickHouseInt256Column(spec: .int256, values: values)
        case .uint256(let values): return ClickHouseUInt256Column(spec: .uint256, values: values)
        case .decimal256(let values, let scale): return try toDecimal256Column(values: values, scale: scale)
        case .bfloat16(let values): return ClickHouseBFloat16Column(spec: .bfloat16, values: values)
        case .json(let values): return ClickHouseStringColumn(spec: .json, values: values)
        case .nullableInt8(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .int8) {
                ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: $0)
            }
        case .nullableInt16(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .int16) {
                ClickHouseFixedWidthIntegerColumn<Int16>(spec: .int16, values: $0)
            }
        case .nullableUInt8(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .uint8) {
                ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: $0)
            }
        case .nullableUInt16(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .uint16) {
                ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .uint16, values: $0)
            }
        case .nullableFloat32(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .float32) {
                ClickHouseFloat32Column(values: $0)
            }
        case .mapStringFloat64(let dicts):
            return Self.makeMapColumn(
                dicts: dicts,
                keySpec: .string, valueSpec: .float64,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseFloat64Column(values: $0) }
            )
        case .mapStringBool(let dicts):
            return Self.makeMapColumn(
                dicts: dicts,
                keySpec: .string, valueSpec: .bool,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseBoolColumn(values: $0) }
            )
        case .mapInt32String(let dicts):
            return Self.makeMapColumn(
                dicts: dicts,
                keySpec: .int32, valueSpec: .string,
                makeKeyColumn: { ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: $0) },
                makeValueColumn: { ClickHouseStringColumn(values: $0) }
            )
        case .mapInt64String(let dicts):
            return Self.makeMapColumn(
                dicts: dicts,
                keySpec: .int64, valueSpec: .string,
                makeKeyColumn: { ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: $0) },
                makeValueColumn: { ClickHouseStringColumn(values: $0) }
            )
        case .arrayOfInt8(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .int8) {
                ClickHouseFixedWidthIntegerColumn<Int8>(spec: .int8, values: $0)
            }
        case .arrayOfInt16(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .int16) {
                ClickHouseFixedWidthIntegerColumn<Int16>(spec: .int16, values: $0)
            }
        case .arrayOfUInt8(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .uint8) {
                ClickHouseFixedWidthIntegerColumn<UInt8>(spec: .uint8, values: $0)
            }
        case .arrayOfUInt16(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .uint16) {
                ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .uint16, values: $0)
            }
        case .arrayOfBFloat16(let arrays):
            return makeArrayColumn(arrays: arrays, elementSpec: .bfloat16) {
                ClickHouseBFloat16Column(spec: .bfloat16, values: $0)
            }
        case .nullableDecimal32(let optionals, let scale): return try toNullableDecimal32Column(nullables: optionals, scale: scale)
        case .nullableDecimal64(let optionals, let scale): return try toNullableDecimal64Column(nullables: optionals, scale: scale)
        case .nullableDecimal128(let optionals, let scale): return try toNullableDecimal128Column(nullables: optionals, scale: scale)
        case .nullableDecimal256(let optionals, let scale): return try toNullableDecimal256Column(nullables: optionals, scale: scale)
        case .nullableDate32(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .date32) {
                ClickHouseFixedWidthIntegerColumn<Int32>(spec: .date32, values: $0)
            }
        case .nullableDateTime64(let optionals, let precision): return try toNullableDateTime64Column(nullables: optionals, precision: precision)
        case .nullableInt128(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .int128) {
                ClickHouseFixedWidthIntegerColumn<Int128>(spec: .int128, values: $0)
            }
        case .nullableUInt128(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .uint128) {
                ClickHouseFixedWidthIntegerColumn<UInt128>(spec: .uint128, values: $0)
            }
        case .nullableInt256(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: ClickHouseInt256.zero, innerSpec: .int256) {
                ClickHouseInt256Column(spec: .int256, values: $0)
            }
        case .nullableUInt256(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: ClickHouseUInt256.zero, innerSpec: .uint256) {
                ClickHouseUInt256Column(spec: .uint256, values: $0)
            }
        case .nullableTime(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .time) {
                ClickHouseFixedWidthIntegerColumn<Int32>(spec: .time, values: $0)
            }
        case .nullableTime64(let optionals, let precision): return try toNullableTime64Column(nullables: optionals, precision: precision)
        case .nullableBFloat16(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: ClickHouseBFloat16.zero, innerSpec: .bfloat16) {
                ClickHouseBFloat16Column(spec: .bfloat16, values: $0)
            }
        case .dateTime64Nanoseconds(let nanos, let precision): return try toDateTime64NanosecondsColumn(nanos: nanos, precision: precision)
        case .nullableDateTime64Nanoseconds(let optionals, let precision): return try toNullableDateTime64NanosecondsColumn(nullables: optionals, precision: precision)
        case .mapStringFloat32(let dicts):
            return makeMapColumn(
                dicts: dicts,
                keySpec: .string,
                valueSpec: .float32,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseFloat32Column(values: $0) }
            )
        case .mapStringUUID(let dicts):
            return makeMapColumn(
                dicts: dicts,
                keySpec: .string,
                valueSpec: .uuid,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseUUIDColumn(values: $0) }
            )
        case .mapStringDateTime(let dicts):
            // Convert each Date value to UInt32 seconds-since-epoch up
            // front, mirroring the leaf .dateTime INSERT path. The map
            // builder receives [UInt32] for the values column.
            let convertedDicts: [[String: UInt32]] = try dicts.map { dict in
                var converted: [String: UInt32] = [:]
                converted.reserveCapacity(dict.count)
                for (key, value) in dict {
                    converted[key] = try Self.toUInt32Seconds(value)
                }
                return converted
            }
            return makeMapColumn(
                dicts: convertedDicts,
                keySpec: .string,
                valueSpec: .dateTime(timezone: .serverDefault),
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .dateTime(timezone: .serverDefault), values: $0) }
            )
        case .mapUInt64Int64(let dicts):
            return makeMapColumn(
                dicts: dicts,
                keySpec: .uint64,
                valueSpec: .int64,
                makeKeyColumn: { ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: $0) },
                makeValueColumn: { ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: $0) }
            )
        case .nullableIPv4(let optionals):
            return makeNullableColumn(nullables: optionals, sentinel: 0, innerSpec: .ipv4) {
                ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .ipv4, values: $0)
            }
        case .nullableIPv6(let optionals): return try toNullableIPv6Column(nullables: optionals)
        case .nullableFixedString(let length, let optionals): return try toNullableFixedStringColumn(length: length, nullables: optionals)
        case .arrayOfTupleFloat64Float64(let rings): return Self.makeRingColumn(from: rings)
        case .arrayOfArrayOfTupleFloat64Float64(let polygons): return Self.makePolygonColumn(from: polygons)
        case .arrayOfArrayOfArrayOfTupleFloat64Float64(let multiPolygons): return Self.makeMultiPolygonColumn(from: multiPolygons)
        case .lowCardinalityString(let values): return Self.makeLowCardinalityStringColumn(values: values)
        case .lowCardinalityStringIndexed(let view):
            // Re-insert fast path: the view already holds a deduplicated
            // dictionary + per-row indices, byte-identical to what the
            // server emitted. Skip a full N-row flatten + N-element
            // re-intern by handing the (dictionary, indices) pair
            // straight into the LowCardinality column.
            return ClickHouseLowCardinalityColumn(
                spec: .lowCardinality(of: .string),
                innerSpec: .string,
                dictionary: ClickHouseStringColumn(values: view.dictionary),
                indices: view.indices
            )
        case .mapStringStringIndexed(let storage):
            return Self.makeMapColumn(
                dicts: Self.flatten(storage),
                keySpec: .string,
                valueSpec: .string,
                makeKeyColumn: { ClickHouseStringColumn(values: $0) },
                makeValueColumn: { ClickHouseStringColumn(values: $0) }
            )
        }
    }

    private static func flatten(_ view: ClickHouseLowCardinalityStringView) -> [String] {
        var result = [String]()
        result.reserveCapacity(view.indices.count)
        for index in view.indices {
            result.append(view.dictionary[Int(index)])
        }
        return result
    }

    private static func flatten(_ storage: ClickHouseMapStringStringStorage) -> [[String: String]] {
        var result = [[String: String]]()
        result.reserveCapacity(storage.count)
        for rowIndex in 0..<storage.count {
            result.append(storage.row(at: rowIndex))
        }
        return result
    }

    private static func toDateColumn(dates: [Date]) throws -> any ClickHouseColumn {
        let days = try dates.map { try toUInt16Days($0) }
        return ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .date, values: days)
    }

    private static func toDate32Column(dates: [Date]) throws -> any ClickHouseColumn {
        let days = try dates.map { try toInt32Days($0) }
        return ClickHouseFixedWidthIntegerColumn<Int32>(spec: .date32, values: days)
    }

    private static func toDateTimeColumn(dates: [Date]) throws -> any ClickHouseColumn {
        let seconds = try dates.map { try toUInt32Seconds($0) }
        return ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .dateTime(timezone: .serverDefault), values: seconds)
    }

    private static func toDateTime64Column(dates: [Date], precision: Int) throws -> any ClickHouseColumn {
        try validatePrecision(precision)
        let scale = dateTime64Scales[precision]
        let ticks = try dates.map { try toInt64Ticks($0, scale: scale) }
        return ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: precision, timezone: .serverDefault),
            values: ticks
        )
    }

    private static func toFixedStringColumn(length: Int, datas: [Data]) throws -> any ClickHouseColumn {
        try validateFixedStringLength(length)
        try requireAllDataLengths(datas: datas, expected: length)
        return ClickHouseFixedStringColumn(spec: .fixedString(length: length), length: length, values: datas)
    }

    private static func requireAllDataLengths(datas: [Data], expected: Int) throws {
        for data in datas where data.count != expected {
            throw ClickHouseError.fixedStringLengthMismatch(expected: expected, actual: data.count)
        }
    }

    private static func toIPv6Column(datas: [Data]) throws -> any ClickHouseColumn {
        try requireAllDataLengths(datas: datas, expected: 16)
        return ClickHouseFixedStringColumn(spec: .ipv6, length: 16, values: datas)
    }

    private static func toDecimal32Column(values: [Int32], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 9)
        return ClickHouseFixedWidthIntegerColumn<Int32>(spec: .decimal32(scale: scale), values: values)
    }

    private static func toDecimal64Column(values: [Int64], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 18)
        return ClickHouseFixedWidthIntegerColumn<Int64>(spec: .decimal64(scale: scale), values: values)
    }

    private static func toDecimal128Column(values: [Int128], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 38)
        return ClickHouseFixedWidthIntegerColumn<Int128>(spec: .decimal128(scale: scale), values: values)
    }

    private static func toDecimal256Column(values: [ClickHouseInt256], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 76)
        return ClickHouseInt256Column(spec: .decimal256(scale: scale), values: values)
    }

    private static func toTime64Column(values: [Int64], precision: Int) throws -> any ClickHouseColumn {
        try validatePrecision(precision)
        return ClickHouseFixedWidthIntegerColumn<Int64>(spec: .time64(precision: precision), values: values)
    }

    private static func toNullableDateColumn(nullables: [ClickHouseNullable<Date>]) throws -> any ClickHouseColumn {
        let converted: [ClickHouseNullable<UInt16>] = try nullables.map { element in
            switch element {
            case .present(let date): return .present(try Self.toUInt16Days(date))
            case .absent: return .absent
            }
        }
        return makeNullableColumn(nullables: converted, sentinel: 0, innerSpec: .date) {
            ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .date, values: $0)
        }
    }

    private static func toNullableDateTimeColumn(nullables: [ClickHouseNullable<Date>]) throws -> any ClickHouseColumn {
        let converted: [ClickHouseNullable<UInt32>] = try nullables.map { element in
            switch element {
            case .present(let date): return .present(try Self.toUInt32Seconds(date))
            case .absent: return .absent
            }
        }
        return makeNullableColumn(nullables: converted, sentinel: 0, innerSpec: .dateTime(timezone: .serverDefault)) {
            ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .dateTime(timezone: .serverDefault), values: $0)
        }
    }

    private static func toNullableDecimal32Column(nullables: [ClickHouseNullable<Int32>], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 9)
        return makeNullableColumn(nullables: nullables, sentinel: 0, innerSpec: .decimal32(scale: scale)) {
            ClickHouseFixedWidthIntegerColumn<Int32>(spec: .decimal32(scale: scale), values: $0)
        }
    }

    private static func toNullableDecimal64Column(nullables: [ClickHouseNullable<Int64>], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 18)
        return makeNullableColumn(nullables: nullables, sentinel: 0, innerSpec: .decimal64(scale: scale)) {
            ClickHouseFixedWidthIntegerColumn<Int64>(spec: .decimal64(scale: scale), values: $0)
        }
    }

    private static func toNullableDecimal128Column(nullables: [ClickHouseNullable<Int128>], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 38)
        return makeNullableColumn(nullables: nullables, sentinel: 0, innerSpec: .decimal128(scale: scale)) {
            ClickHouseFixedWidthIntegerColumn<Int128>(spec: .decimal128(scale: scale), values: $0)
        }
    }

    private static func toNullableDecimal256Column(nullables: [ClickHouseNullable<ClickHouseInt256>], scale: Int) throws -> any ClickHouseColumn {
        try validateDecimalScale(scale, maxScale: 76)
        return makeNullableColumn(nullables: nullables, sentinel: ClickHouseInt256.zero, innerSpec: .decimal256(scale: scale)) {
            ClickHouseInt256Column(spec: .decimal256(scale: scale), values: $0)
        }
    }

    private static func toNullableDateTime64Column(nullables: [ClickHouseNullable<Int64>], precision: Int) throws -> any ClickHouseColumn {
        try validatePrecision(precision)
        let spec = ClickHouseColumnSpec.dateTime64(precision: precision, timezone: .serverDefault)
        return makeNullableColumn(nullables: nullables, sentinel: 0, innerSpec: spec) {
            ClickHouseFixedWidthIntegerColumn<Int64>(spec: spec, values: $0)
        }
    }

    private static func toNullableTime64Column(nullables: [ClickHouseNullable<Int64>], precision: Int) throws -> any ClickHouseColumn {
        try validatePrecision(precision)
        return makeNullableColumn(nullables: nullables, sentinel: 0, innerSpec: .time64(precision: precision)) {
            ClickHouseFixedWidthIntegerColumn<Int64>(spec: .time64(precision: precision), values: $0)
        }
    }

    private static func toDateTime64NanosecondsColumn(nanos: [ClickHouseNanoseconds], precision: Int) throws -> any ClickHouseColumn {
        try validatePrecision(precision)
        let divisor = nanosecondsToColumnDivisor(precision: precision)
        let ticks = nanos.map { Self.flooredDivide($0.rawValue, by: divisor) }
        return ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .dateTime64(precision: precision, timezone: .serverDefault),
            values: ticks
        )
    }

    private static func toNullableDateTime64NanosecondsColumn(nullables: [ClickHouseNullable<ClickHouseNanoseconds>], precision: Int) throws -> any ClickHouseColumn {
        try validatePrecision(precision)
        let divisor = nanosecondsToColumnDivisor(precision: precision)
        let spec = ClickHouseColumnSpec.dateTime64(precision: precision, timezone: .serverDefault)
        let (mask, inner) = splitNullableNanoseconds(nullables: nullables, divisor: divisor)
        let innerColumn = ClickHouseFixedWidthIntegerColumn<Int64>(spec: spec, values: inner)
        return ClickHouseNullableColumn(
            spec: .nullable(of: spec),
            innerSpec: spec,
            nullMask: mask,
            inner: innerColumn
        )
    }

    private static func splitNullableNanoseconds(
        nullables: [ClickHouseNullable<ClickHouseNanoseconds>],
        divisor: Int64
    ) -> (mask: [Bool], inner: [Int64]) {
        var inner: [Int64] = []
        var mask: [Bool] = []
        inner.reserveCapacity(nullables.count)
        mask.reserveCapacity(nullables.count)
        for element in nullables {
            appendNullableNanoseconds(element: element, divisor: divisor, mask: &mask, inner: &inner)
        }
        return (mask, inner)
    }

    private static func appendNullableNanoseconds(
        element: ClickHouseNullable<ClickHouseNanoseconds>,
        divisor: Int64,
        mask: inout [Bool],
        inner: inout [Int64]
    ) {
        switch element {
        case .present(let nanoseconds):
            inner.append(Self.flooredDivide(nanoseconds.rawValue, by: divisor))
            mask.append(false)
        case .absent:
            inner.append(0)
            mask.append(true)
        }
    }

    private static func toArrayOfDateColumn(arrays: [[Date]]) throws -> any ClickHouseColumn {
        let convertedArrays = try arrays.map { row in
            try row.map { try Self.toUInt16Days($0) }
        }
        return makeArrayColumn(arrays: convertedArrays, elementSpec: .date) {
            ClickHouseFixedWidthIntegerColumn<UInt16>(spec: .date, values: $0)
        }
    }

    private static func toArrayOfDateTimeColumn(arrays: [[Date]]) throws -> any ClickHouseColumn {
        let convertedArrays = try arrays.map { row in
            try row.map { try Self.toUInt32Seconds($0) }
        }
        return makeArrayColumn(arrays: convertedArrays, elementSpec: .dateTime(timezone: .serverDefault)) {
            ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .dateTime(timezone: .serverDefault), values: $0)
        }
    }

    private static func toNullableIPv6Column(nullables: [ClickHouseNullable<Data>]) throws -> any ClickHouseColumn {
        try requireAllNullableDataLengths(nullables: nullables, expected: 16)
        let sentinel = Data(repeating: 0, count: 16)
        return makeNullableColumn(nullables: nullables, sentinel: sentinel, innerSpec: .ipv6) {
            ClickHouseFixedStringColumn(spec: .ipv6, length: 16, values: $0)
        }
    }

    private static func toNullableFixedStringColumn(length: Int, nullables: [ClickHouseNullable<Data>]) throws -> any ClickHouseColumn {
        try validateFixedStringLength(length)
        try requireAllNullableDataLengths(nullables: nullables, expected: length)
        let innerSpec = ClickHouseColumnSpec.fixedString(length: length)
        let sentinel = Data(repeating: 0, count: length)
        return makeNullableColumn(nullables: nullables, sentinel: sentinel, innerSpec: innerSpec) {
            ClickHouseFixedStringColumn(spec: innerSpec, length: length, values: $0)
        }
    }

    private static func requireAllNullableDataLengths(nullables: [ClickHouseNullable<Data>], expected: Int) throws {
        for element in nullables {
            if case .present(let value) = element, value.count != expected {
                throw ClickHouseError.fixedStringLengthMismatch(expected: expected, actual: value.count)
            }
        }
    }

    private static func toTupleStringStringColumn(pairs: [(String, String)]) -> any ClickHouseColumn {
        let firstColumn = ClickHouseStringColumn(values: pairs.map(\.0))
        let secondColumn = ClickHouseStringColumn(values: pairs.map(\.1))
        return ClickHouseTupleColumn(
            spec: .tuple(elements: [.string, .string]),
            elementSpecs: [.string, .string],
            elements: [firstColumn, secondColumn],
            rowCount: pairs.count
        )
    }

    private static func toTupleStringInt32Column(pairs: [(String, Int32)]) -> any ClickHouseColumn {
        let firstColumn = ClickHouseStringColumn(values: pairs.map(\.0))
        let secondColumn = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: pairs.map(\.1))
        return ClickHouseTupleColumn(
            spec: .tuple(elements: [.string, .int32]),
            elementSpecs: [.string, .int32],
            elements: [firstColumn, secondColumn],
            rowCount: pairs.count
        )
    }

    private static func toTupleStringInt64Column(pairs: [(String, Int64)]) -> any ClickHouseColumn {
        let firstColumn = ClickHouseStringColumn(values: pairs.map(\.0))
        let secondColumn = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: pairs.map(\.1))
        return ClickHouseTupleColumn(
            spec: .tuple(elements: [.string, .int64]),
            elementSpecs: [.string, .int64],
            elements: [firstColumn, secondColumn],
            rowCount: pairs.count
        )
    }

    private static func toTupleFloat64Float64Column(pairs: [(Double, Double)]) -> any ClickHouseColumn {
        let firstColumn = ClickHouseFloat64Column(values: pairs.map(\.0))
        let secondColumn = ClickHouseFloat64Column(values: pairs.map(\.1))
        return ClickHouseTupleColumn(
            spec: .tuple(elements: [.float64, .float64]),
            elementSpecs: [.float64, .float64],
            elements: [firstColumn, secondColumn],
            rowCount: pairs.count
        )
    }

    // Polygon = Array(Ring). Outer offsets count rings per polygon row,
    // then the flattened-rings array becomes the inner Ring column.
    private static func makePolygonColumn(from polygons: [[[(Double, Double)]]]) -> ClickHouseArrayColumn {
        var outerOffsets: [UInt64] = []
        var allRings: [[(Double, Double)]] = []
        var cumulative: UInt64 = 0
        outerOffsets.reserveCapacity(polygons.count)
        for polygon in polygons {
            cumulative += UInt64(polygon.count)
            outerOffsets.append(cumulative)
            allRings.append(contentsOf: polygon)
        }
        let ringColumn = Self.makeRingColumn(from: allRings)
        return ClickHouseArrayColumn(
            spec: .array(of: ringColumn.spec),
            elementSpec: ringColumn.spec,
            offsets: outerOffsets,
            inner: ringColumn
        )
    }

    // MultiPolygon = Array(Polygon). One more wrapping level over Polygon.
    private static func makeMultiPolygonColumn(from multiPolygons: [[[[(Double, Double)]]]]) -> ClickHouseArrayColumn {
        let (outerOffsets, allPolygons) = flattenMultiPolygonOuter(multiPolygons: multiPolygons)
        let (ringOffsets, allRings) = flattenPolygonsToRings(polygons: allPolygons)
        let ringColumn = Self.makeRingColumn(from: allRings)
        let polygonColumn = ClickHouseArrayColumn(
            spec: .array(of: ringColumn.spec),
            elementSpec: ringColumn.spec,
            offsets: ringOffsets,
            inner: ringColumn
        )
        return ClickHouseArrayColumn(
            spec: .array(of: polygonColumn.spec),
            elementSpec: polygonColumn.spec,
            offsets: outerOffsets,
            inner: polygonColumn
        )
    }

    private static func flattenMultiPolygonOuter(multiPolygons: [[[[(Double, Double)]]]]) -> (offsets: [UInt64], polygons: [[[(Double, Double)]]]) {
        var offsets: [UInt64] = []
        var allPolygons: [[[(Double, Double)]]] = []
        var cumulative: UInt64 = 0
        offsets.reserveCapacity(multiPolygons.count)
        for multiPolygon in multiPolygons {
            cumulative += UInt64(multiPolygon.count)
            offsets.append(cumulative)
            allPolygons.append(contentsOf: multiPolygon)
        }
        return (offsets, allPolygons)
    }

    private static func flattenPolygonsToRings(polygons: [[[(Double, Double)]]]) -> (offsets: [UInt64], rings: [[(Double, Double)]]) {
        var offsets: [UInt64] = []
        var allRings: [[(Double, Double)]] = []
        var cumulative: UInt64 = 0
        for polygon in polygons {
            cumulative += UInt64(polygon.count)
            offsets.append(cumulative)
            allRings.append(contentsOf: polygon)
        }
        return (offsets, allRings)
    }

    private static func makeLowCardinalityStringColumn(values: [String]) -> ClickHouseLowCardinalityColumn {
        var dictionary: [String] = []
        var dictMap: [String: UInt64] = [:]
        var indices: [UInt64] = []
        indices.reserveCapacity(values.count)
        for value in values {
            indices.append(internLowCardinalityString(value, dictionary: &dictionary, dictMap: &dictMap))
        }
        return ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: dictionary),
            indices: indices
        )
    }

    private static func internLowCardinalityString(_ value: String, dictionary: inout [String], dictMap: inout [String: UInt64]) -> UInt64 {
        if let existing = dictMap[value] { return existing }
        let newIndex = UInt64(dictionary.count)
        dictMap[value] = newIndex
        dictionary.append(value)
        return newIndex
    }

    // Ring = Array(Tuple(Float64, Float64)). Each input row is an array of
    // (x, y) tuples. Flattens to a single TupleColumn of two parallel
    // Float64 children, then wraps in an ArrayColumn whose element spec is
    // the tuple type. Used directly for Ring INSERTs and recursively by
    // Polygon / MultiPolygon construction.
    private static func makeRingColumn(from rings: [[(Double, Double)]]) -> ClickHouseArrayColumn {
        var offsets: [UInt64] = []
        var firsts: [Double] = []
        var seconds: [Double] = []
        var cumulative: UInt64 = 0
        offsets.reserveCapacity(rings.count)
        for ring in rings {
            cumulative += UInt64(ring.count)
            offsets.append(cumulative)
            for pair in ring {
                firsts.append(pair.0)
                seconds.append(pair.1)
            }
        }
        let tupleColumn = ClickHouseTupleColumn(
            spec: .tuple(elements: [.float64, .float64]),
            elementSpecs: [.float64, .float64],
            elements: [
                ClickHouseFloat64Column(values: firsts),
                ClickHouseFloat64Column(values: seconds)
            ],
            rowCount: firsts.count
        )
        return ClickHouseArrayColumn(
            spec: .array(of: .tuple(elements: [.float64, .float64])),
            elementSpec: .tuple(elements: [.float64, .float64]),
            offsets: offsets,
            inner: tupleColumn
        )
    }

    private static func makeMapColumn<K: Hashable, V, KeyColumn: ClickHouseColumn, ValueColumn: ClickHouseColumn>(
        dicts: [[K: V]],
        keySpec: ClickHouseColumnSpec,
        valueSpec: ClickHouseColumnSpec,
        makeKeyColumn: ([K]) -> KeyColumn,
        makeValueColumn: ([V]) -> ValueColumn
    ) -> ClickHouseMapColumn {
        var offsets: [UInt64] = []
        var keys: [K] = []
        var values: [V] = []
        var cumulative: UInt64 = 0
        offsets.reserveCapacity(dicts.count)
        keys.reserveCapacity(dicts.reduce(0) { $0 + $1.count })
        values.reserveCapacity(keys.capacity)
        for dict in dicts {
            cumulative += UInt64(dict.count)
            offsets.append(cumulative)
            for (k, v) in dict {
                keys.append(k)
                values.append(v)
            }
        }
        return ClickHouseMapColumn(
            spec: .map(key: keySpec, value: valueSpec),
            keySpec: keySpec,
            valueSpec: valueSpec,
            offsets: offsets,
            keys: makeKeyColumn(keys),
            values: makeValueColumn(values)
        )
    }

    private static func makeArrayColumn<T, Inner: ClickHouseColumn>(
        arrays: [[T]],
        elementSpec: ClickHouseColumnSpec,
        innerBuilder: ([T]) -> Inner
    ) -> ClickHouseArrayColumn {
        var offsets: [UInt64] = []
        var flattened: [T] = []
        var cumulative: UInt64 = 0
        offsets.reserveCapacity(arrays.count)
        flattened.reserveCapacity(arrays.reduce(0) { $0 + $1.count })
        for array in arrays {
            cumulative += UInt64(array.count)
            offsets.append(cumulative)
            flattened.append(contentsOf: array)
        }
        return ClickHouseArrayColumn(
            spec: .array(of: elementSpec),
            elementSpec: elementSpec,
            offsets: offsets,
            inner: innerBuilder(flattened)
        )
    }

    private static func makeNullableColumn<T, Inner: ClickHouseColumn>(
        nullables: [ClickHouseNullable<T>],
        sentinel: T,
        innerSpec: ClickHouseColumnSpec,
        innerBuilder: ([T]) -> Inner
    ) -> ClickHouseNullableColumn {
        let (nullMask, values) = splitNullables(nullables: nullables, sentinel: sentinel)
        return ClickHouseNullableColumn(
            spec: .nullable(of: innerSpec),
            innerSpec: innerSpec,
            nullMask: nullMask,
            inner: innerBuilder(values)
        )
    }

    private static func splitNullables<T>(
        nullables: [ClickHouseNullable<T>],
        sentinel: T
    ) -> (mask: [Bool], values: [T]) {
        var nullMask: [Bool] = []
        var values: [T] = []
        nullMask.reserveCapacity(nullables.count)
        values.reserveCapacity(nullables.count)
        for element in nullables {
            appendNullable(element: element, sentinel: sentinel, mask: &nullMask, values: &values)
        }
        return (nullMask, values)
    }

    private static func appendNullable<T>(
        element: ClickHouseNullable<T>,
        sentinel: T,
        mask: inout [Bool],
        values: inout [T]
    ) {
        switch element {
        case .present(let value):
            mask.append(false)
            values.append(value)
        case .absent:
            mask.append(true)
            values.append(sentinel)
        }
    }

    private static func toUInt16Days(_ date: Date) throws -> UInt16 {
        let seconds = date.timeIntervalSince1970
        let days = floor(seconds / secondsPerDay)
        guard days >= 0, days <= Double(UInt16.max) else {
            throw ClickHouseError.dateValueOutOfRange(
                seconds: seconds,
                lowerBound: 0,
                upperBound: Double(UInt16.max) * secondsPerDay
            )
        }
        return UInt16(days)
    }

    private static func toInt32Days(_ date: Date) throws -> Int32 {
        let seconds = date.timeIntervalSince1970
        let days = floor(seconds / secondsPerDay)
        guard days >= Double(Int32.min), days <= Double(Int32.max) else {
            throw ClickHouseError.dateValueOutOfRange(
                seconds: seconds,
                lowerBound: Double(Int32.min) * secondsPerDay,
                upperBound: Double(Int32.max) * secondsPerDay
            )
        }
        return Int32(days)
    }

    private static func toUInt32Seconds(_ date: Date) throws -> UInt32 {
        let seconds = date.timeIntervalSince1970
        guard seconds >= 0, seconds <= Double(UInt32.max) else {
            throw ClickHouseError.dateValueOutOfRange(
                seconds: seconds,
                lowerBound: 0,
                upperBound: Double(UInt32.max)
            )
        }
        return UInt32(seconds)
    }

    private static func toInt64Ticks(_ date: Date, scale: Double) throws -> Int64 {
        let ticks = date.timeIntervalSince1970 * scale
        // Floor toward minus infinity rather than truncate toward zero.
        // Without this, a pre-1970 Date with sub-precision fractional
        // (e.g., -0.5 sec at precision 0) would map to ticks = 0 instead
        // of -1, silently shifting the stored value FORWARD by one
        // precision-tick. Floor places the moment in the precision-tick
        // it actually belongs to. Symmetric with the integer-side
        // `flooredDivide` used for the `.dateTime64Nanoseconds` path
        // and with the Date/Date32 paths that already use `floor(...)`.
        let floored = ticks.rounded(.down)
        // `Double(Int64.max)` rounds up to 2^63 (i.e., Int64.max + 1)
        // because the closest representable Double to 9_223_372_036_854_775_807
        // is the next power of two. A `ticks` value at exactly that
        // boundary would pass `<=` but trap during `Int64(ticks)`.
        // Use strict `<` on the upper bound so the trap is unreachable.
        // The lower bound is exact (`-2^63 == Int64.min`) so `>=` is fine.
        guard floored >= Double(Int64.min), floored < Double(Int64.max) else {
            throw ClickHouseError.dateValueOutOfRange(
                seconds: date.timeIntervalSince1970,
                lowerBound: Double(Int64.min) / scale,
                upperBound: Double(Int64.max) / scale
            )
        }
        return Int64(floored)
    }

    // Integer floor division: matches Python's `//` semantics for any
    // sign of `value` (the divisor is always positive in this client's
    // call sites — `nanosecondsToColumnDivisor` returns >= 1). Swift's
    // built-in `/` on signed integers truncates toward zero, which for
    // negative values produces the "next" precision-tick instead of the
    // containing one. ClickHouse and ch-go both store pre-epoch ticks
    // under floor convention, so this matches the wire semantics.
    private static func flooredDivide(_ value: Int64, by divisor: Int64) -> Int64 {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }

    private static func validatePrecision(_ precision: Int) throws {
        guard (0...9).contains(precision) else {
            throw ClickHouseError.invalidDateTime64Precision(precision)
        }
    }

    // CH's `Decimal*(scale)` accepts scale in `[0, maxScale]` per the
    // backing integer width: Decimal32 → 9, Decimal64 → 18, Decimal128
    // → 38, Decimal256 → 76. Validating client-side surfaces the misuse
    // immediately as a typed error instead of waiting for the server to
    // reject the type-name with a generic SQL exception after a wire
    // round-trip.
    private static func validateDecimalScale(_ scale: Int, maxScale: Int) throws {
        guard (0...maxScale).contains(scale) else {
            throw ClickHouseError.invalidDecimalScale(scale: scale, maxScale: maxScale)
        }
    }

    // CH's `FixedString(N)` requires `N >= 1`. A zero or negative length
    // is invalid; the codec layer's `ClickHouseFixedStringColumn.encode`
    // already rejects it via `invalidFixedStringLength`, but for the
    // nullable variant the sentinel is built before encode runs and
    // `Data(repeating: 0, count: negative)` traps in Foundation. Catch
    // it here so the public API surfaces a typed error instead of a
    // process crash.
    private static func validateFixedStringLength(_ length: Int) throws {
        guard length > 0 else {
            throw ClickHouseError.invalidFixedStringLength(length)
        }
    }

}
