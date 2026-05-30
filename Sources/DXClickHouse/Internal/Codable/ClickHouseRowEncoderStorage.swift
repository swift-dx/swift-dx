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

// Backs the encoder's accumulating state across multiple rows. Holds
// one typed bucket per column observed so far, plus the cross-row
// invariants required to surface a meaningful schema-mismatch error:
//
//   * The first row defines the column set, order, and per-column
//     ClickHouse type. The order matches the order of `encode(_:forKey:)`
//     calls observed during that row (Codable runs synthesised
//     `encode(to:)` in the lexical field order Swift declared them).
//   * Subsequent rows must touch every column the first row registered.
//     A row that omits a column raises `encoderRowMissingColumns`. A
//     row that introduces a NEW column raises
//     `encoderUnexpectedColumn`. A row that re-uses a column name but
//     with a different Swift type raises `encoderColumnTypeMismatch`.
final class ClickHouseRowEncoderStorage {

    private var columns: [Slot] = []
    private var columnIndexByName: [String: Int] = [:]
    private var rowsEncoded: Int = 0
    private var touched: [Bool] = []
    private var isFirstRow: Bool { rowsEncoded == 0 }

    func beginRow() {
        for index in touched.indices { touched[index] = false }
    }

    func endRow() throws(ClickHouseError) {
        for (index, was) in touched.enumerated() where !was {
            throw .protocolError(
                stage: "encoder.endRow",
                message: "row \(rowsEncoded) missing column '\(columns[index].name)'; every row must encode every column declared by row 0"
            )
        }
        rowsEncoded += 1
    }

    func materialize() -> [ClickHouseNamedColumn] {
        columns.map { ClickHouseNamedColumn(name: $0.name, column: $0.snapshot()) }
    }

    func appendString(_ value: String, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .string) { $0.appendString(value) }
    }

    func appendNullableString(_ value: ClickHouseNullable<String>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableString) { $0.appendNullableString(value) }
    }

    func appendBool(_ value: Bool, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .bool) { $0.appendBool(value) }
    }

    func appendNullableBool(_ value: ClickHouseNullable<Bool>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableBool) { $0.appendNullableBool(value) }
    }

    func appendInt8(_ value: Int8, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .int8) { $0.appendInt8(value) }
    }

    func appendInt16(_ value: Int16, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .int16) { $0.appendInt16(value) }
    }

    func appendInt32(_ value: Int32, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .int32) { $0.appendInt32(value) }
    }

    func appendInt64(_ value: Int64, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .int64) { $0.appendInt64(value) }
    }

    func appendNullableInt8(_ value: ClickHouseNullable<Int8>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableInt8) { $0.appendNullableInt8(value) }
    }

    func appendNullableInt16(_ value: ClickHouseNullable<Int16>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableInt16) { $0.appendNullableInt16(value) }
    }

    func appendNullableInt32(_ value: ClickHouseNullable<Int32>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableInt32) { $0.appendNullableInt32(value) }
    }

    func appendNullableInt64(_ value: ClickHouseNullable<Int64>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableInt64) { $0.appendNullableInt64(value) }
    }

    func appendUInt8(_ value: UInt8, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .uint8) { $0.appendUInt8(value) }
    }

    func appendUInt16(_ value: UInt16, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .uint16) { $0.appendUInt16(value) }
    }

    func appendUInt32(_ value: UInt32, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .uint32) { $0.appendUInt32(value) }
    }

    func appendUInt64(_ value: UInt64, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .uint64) { $0.appendUInt64(value) }
    }

    func appendNullableUInt8(_ value: ClickHouseNullable<UInt8>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableUInt8) { $0.appendNullableUInt8(value) }
    }

    func appendNullableUInt16(_ value: ClickHouseNullable<UInt16>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableUInt16) { $0.appendNullableUInt16(value) }
    }

    func appendNullableUInt32(_ value: ClickHouseNullable<UInt32>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableUInt32) { $0.appendNullableUInt32(value) }
    }

    func appendNullableUInt64(_ value: ClickHouseNullable<UInt64>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableUInt64) { $0.appendNullableUInt64(value) }
    }

    func appendFloat(_ value: Float, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .float32) { $0.appendFloat(value) }
    }

    func appendDouble(_ value: Double, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .float64) { $0.appendDouble(value) }
    }

    func appendNullableFloat(_ value: ClickHouseNullable<Float>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableFloat32) { $0.appendNullableFloat(value) }
    }

    func appendNullableDouble(_ value: ClickHouseNullable<Double>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableFloat64) { $0.appendNullableDouble(value) }
    }

    func appendDateTime(_ value: Date, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .dateTime) { $0.appendDateTime(value) }
    }

    func appendNullableDateTime(_ value: ClickHouseNullable<Date>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableDateTime) { $0.appendNullableDateTime(value) }
    }

    func appendUUID(_ value: UUID, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .uuid) { $0.appendUUID(value) }
    }

    func appendNullableUUID(_ value: ClickHouseNullable<UUID>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableUUID) { $0.appendNullableUUID(value) }
    }

    private func append(name: String, kind: SlotKind, _ body: (Slot) -> Void) throws(ClickHouseError) {
        let slotIndex = try resolveSlot(name: name, kind: kind)
        body(columns[slotIndex])
        touched[slotIndex] = true
    }

    private func resolveSlot(name: String, kind: SlotKind) throws(ClickHouseError) -> Int {
        if let existing = columnIndexByName[name] {
            try requireSameKind(existing: existing, incoming: kind, name: name)
            return existing
        }
        guard isFirstRow else {
            throw .protocolError(
                stage: "encoder.append",
                message: "row \(rowsEncoded) introduces previously-unseen column '\(name)'; row 0 declares the column set"
            )
        }
        let newIndex = columns.count
        columns.append(Slot(name: name, kind: kind))
        columnIndexByName[name] = newIndex
        touched.append(false)
        return newIndex
    }

    private func requireSameKind(existing: Int, incoming: SlotKind, name: String) throws(ClickHouseError) {
        let existingKind = columns[existing].kind
        if existingKind != incoming {
            throw .protocolError(
                stage: "encoder.append",
                message: "column '\(name)' declared as \(existingKind) by row 0, got \(incoming) on row \(rowsEncoded)"
            )
        }
    }
}

enum SlotKind: Equatable, CustomStringConvertible {
    case string, nullableString
    case bool, nullableBool
    case int8, int16, int32, int64
    case nullableInt8, nullableInt16, nullableInt32, nullableInt64
    case uint8, uint16, uint32, uint64
    case nullableUInt8, nullableUInt16, nullableUInt32, nullableUInt64
    case float32, float64, nullableFloat32, nullableFloat64
    case dateTime, nullableDateTime
    case uuid, nullableUUID

    var description: String {
        switch self {
        case .string: "String"
        case .nullableString: "Nullable(String)"
        case .bool: "Bool"
        case .nullableBool: "Nullable(Bool)"
        case .int8: "Int8"
        case .int16: "Int16"
        case .int32: "Int32"
        case .int64: "Int64"
        case .nullableInt8: "Nullable(Int8)"
        case .nullableInt16: "Nullable(Int16)"
        case .nullableInt32: "Nullable(Int32)"
        case .nullableInt64: "Nullable(Int64)"
        case .uint8: "UInt8"
        case .uint16: "UInt16"
        case .uint32: "UInt32"
        case .uint64: "UInt64"
        case .nullableUInt8: "Nullable(UInt8)"
        case .nullableUInt16: "Nullable(UInt16)"
        case .nullableUInt32: "Nullable(UInt32)"
        case .nullableUInt64: "Nullable(UInt64)"
        case .float32: "Float32"
        case .float64: "Float64"
        case .nullableFloat32: "Nullable(Float32)"
        case .nullableFloat64: "Nullable(Float64)"
        case .dateTime: "DateTime"
        case .nullableDateTime: "Nullable(DateTime)"
        case .uuid: "UUID"
        case .nullableUUID: "Nullable(UUID)"
        }
    }
}

// One typed accumulator per column. Bodies are flat Swift arrays held
// internally by the slot; `snapshot()` lifts them into the public
// `ClickHouseTypedColumn` case at the end of `materialize()`. The
// indirection lets `append(name:kind:)` reach the same slot across many
// rows without re-resolving the enum case each time.
final class Slot {

    let name: String
    let kind: SlotKind

    private var stringValues: [String] = []
    private var nullableStringValues: [ClickHouseNullable<String>] = []
    private var boolValues: [Bool] = []
    private var nullableBoolValues: [ClickHouseNullable<Bool>] = []
    private var int8Values: [Int8] = []
    private var int16Values: [Int16] = []
    private var int32Values: [Int32] = []
    private var int64Values: [Int64] = []
    private var nullableInt8Values: [ClickHouseNullable<Int8>] = []
    private var nullableInt16Values: [ClickHouseNullable<Int16>] = []
    private var nullableInt32Values: [ClickHouseNullable<Int32>] = []
    private var nullableInt64Values: [ClickHouseNullable<Int64>] = []
    private var uint8Values: [UInt8] = []
    private var uint16Values: [UInt16] = []
    private var uint32Values: [UInt32] = []
    private var uint64Values: [UInt64] = []
    private var nullableUInt8Values: [ClickHouseNullable<UInt8>] = []
    private var nullableUInt16Values: [ClickHouseNullable<UInt16>] = []
    private var nullableUInt32Values: [ClickHouseNullable<UInt32>] = []
    private var nullableUInt64Values: [ClickHouseNullable<UInt64>] = []
    private var float32Values: [Float] = []
    private var float64Values: [Double] = []
    private var nullableFloat32Values: [ClickHouseNullable<Float>] = []
    private var nullableFloat64Values: [ClickHouseNullable<Double>] = []
    private var dateTimeValues: [Date] = []
    private var nullableDateTimeValues: [ClickHouseNullable<Date>] = []
    private var uuidValues: [UUID] = []
    private var nullableUUIDValues: [ClickHouseNullable<UUID>] = []

    init(name: String, kind: SlotKind) {
        self.name = name
        self.kind = kind
    }

    func appendString(_ value: String) { stringValues.append(value) }
    func appendNullableString(_ value: ClickHouseNullable<String>) { nullableStringValues.append(value) }
    func appendBool(_ value: Bool) { boolValues.append(value) }
    func appendNullableBool(_ value: ClickHouseNullable<Bool>) { nullableBoolValues.append(value) }
    func appendInt8(_ value: Int8) { int8Values.append(value) }
    func appendInt16(_ value: Int16) { int16Values.append(value) }
    func appendInt32(_ value: Int32) { int32Values.append(value) }
    func appendInt64(_ value: Int64) { int64Values.append(value) }
    func appendNullableInt8(_ value: ClickHouseNullable<Int8>) { nullableInt8Values.append(value) }
    func appendNullableInt16(_ value: ClickHouseNullable<Int16>) { nullableInt16Values.append(value) }
    func appendNullableInt32(_ value: ClickHouseNullable<Int32>) { nullableInt32Values.append(value) }
    func appendNullableInt64(_ value: ClickHouseNullable<Int64>) { nullableInt64Values.append(value) }
    func appendUInt8(_ value: UInt8) { uint8Values.append(value) }
    func appendUInt16(_ value: UInt16) { uint16Values.append(value) }
    func appendUInt32(_ value: UInt32) { uint32Values.append(value) }
    func appendUInt64(_ value: UInt64) { uint64Values.append(value) }
    func appendNullableUInt8(_ value: ClickHouseNullable<UInt8>) { nullableUInt8Values.append(value) }
    func appendNullableUInt16(_ value: ClickHouseNullable<UInt16>) { nullableUInt16Values.append(value) }
    func appendNullableUInt32(_ value: ClickHouseNullable<UInt32>) { nullableUInt32Values.append(value) }
    func appendNullableUInt64(_ value: ClickHouseNullable<UInt64>) { nullableUInt64Values.append(value) }
    func appendFloat(_ value: Float) { float32Values.append(value) }
    func appendDouble(_ value: Double) { float64Values.append(value) }
    func appendNullableFloat(_ value: ClickHouseNullable<Float>) { nullableFloat32Values.append(value) }
    func appendNullableDouble(_ value: ClickHouseNullable<Double>) { nullableFloat64Values.append(value) }
    func appendDateTime(_ value: Date) { dateTimeValues.append(value) }
    func appendNullableDateTime(_ value: ClickHouseNullable<Date>) { nullableDateTimeValues.append(value) }
    func appendUUID(_ value: UUID) { uuidValues.append(value) }
    func appendNullableUUID(_ value: ClickHouseNullable<UUID>) { nullableUUIDValues.append(value) }

    func snapshot() -> ClickHouseTypedColumn {
        switch kind {
        case .string: .string(stringValues)
        case .nullableString: .nullableString(nullableStringValues)
        case .bool: .bool(boolValues)
        case .nullableBool: .nullableBool(nullableBoolValues)
        case .int8: .int8(int8Values)
        case .int16: .int16(int16Values)
        case .int32: .int32(int32Values)
        case .int64: .int64(int64Values)
        case .nullableInt8: .nullableInt8(nullableInt8Values)
        case .nullableInt16: .nullableInt16(nullableInt16Values)
        case .nullableInt32: .nullableInt32(nullableInt32Values)
        case .nullableInt64: .nullableInt64(nullableInt64Values)
        case .uint8: .uint8(uint8Values)
        case .uint16: .uint16(uint16Values)
        case .uint32: .uint32(uint32Values)
        case .uint64: .uint64(uint64Values)
        case .nullableUInt8: .nullableUInt8(nullableUInt8Values)
        case .nullableUInt16: .nullableUInt16(nullableUInt16Values)
        case .nullableUInt32: .nullableUInt32(nullableUInt32Values)
        case .nullableUInt64: .nullableUInt64(nullableUInt64Values)
        case .float32: .float32(float32Values)
        case .float64: .float64(float64Values)
        case .nullableFloat32: .nullableFloat32(nullableFloat32Values)
        case .nullableFloat64: .nullableFloat64(nullableFloat64Values)
        case .dateTime: .dateTime(dateTimeValues)
        case .nullableDateTime: .nullableDateTime(nullableDateTimeValues)
        case .uuid: .uuid(uuidValues)
        case .nullableUUID: .nullableUUID(nullableUUIDValues)
        }
    }
}
