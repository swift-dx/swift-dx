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

// Tracks per-column accumulators across rows. Per-row state: how
// many columns the current row has touched (for missing-column
// detection on `endRow`) and the bitmap of which column indices
// have been seen.
//
// The first row establishes the column order; subsequent rows look
// up columns by name in `slotIndexByName` and then index directly
// into `columns` — no per-append dictionary write, no per-append
// CoW dance.
final class ClickHouseRowColumnStorage {

    private var columns: [ClickHouseRowColumnAccumulator] = []
    private var columnNames: [String] = []
    private var slotIndexByName: [String: Int] = [:]
    private var rowCount: Int = 0
    private var columnsTouchedThisRow: [Bool] = []
    private var columnsTouchedCount: Int = 0
    private var nextExpectedSlotIndex: Int = 0
    private var schemaLocked: Bool = false
    private var currentRowIsInOrder: Bool = true

    func beginRow() throws {
        resetTouchMaskForNewRow()
        columnsTouchedCount = 0
        nextExpectedSlotIndex = 0
        currentRowIsInOrder = true
    }

    private func resetTouchMaskForNewRow() {
        if !schemaLocked {
            columnsTouchedThisRow.removeAll(keepingCapacity: true)
            return
        }
        if currentRowIsInOrder { return }
        clearLockedTouchMask()
    }

    private func clearLockedTouchMask() {
        for index in columnsTouchedThisRow.indices {
            columnsTouchedThisRow[index] = false
        }
    }

    func endRow() throws {
        schemaLocked = true
        if columnsTouchedCount != columnNames.count {
            try throwMissingColumns()
        }
        rowCount += 1
    }

    private func throwMissingColumns() throws -> Never {
        let missing = currentRowIsInOrder && schemaLocked
            ? missingColumnNamesFromInOrderPrefix()
            : missingColumnNamesFromTouchMask()
        throw ClickHouseError.rowEncoderRowMissingColumns(
            missingColumns: missing.sorted(),
            rowIndex: rowCount
        )
    }

    private func missingColumnNamesFromInOrderPrefix() -> [String] {
        var missing: [String] = []
        for index in nextExpectedSlotIndex..<columnNames.count {
            missing.append(columnNames[index])
        }
        return missing
    }

    private func missingColumnNamesFromTouchMask() -> [String] {
        var missing: [String] = []
        for index in columnsTouchedThisRow.indices where !columnsTouchedThisRow[index] {
            missing.append(columnNames[index])
        }
        return missing
    }

    func materialize() -> [ClickHouseColumnEntry] {
        var result: [ClickHouseColumnEntry] = []
        result.reserveCapacity(columnNames.count)
        for index in columnNames.indices {
            result.append(ClickHouseColumnEntry(name: columnNames[index], values: columns[index].toValues()))
        }
        return result
    }

    func appendString(_ value: String, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<String>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .string(buffer))
            return
        }
        if case .string(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "String")
    }

    func appendBool(_ value: Bool, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Bool>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .bool(buffer))
            return
        }
        if case .bool(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Bool")
    }

    func appendInt8(_ value: Int8, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Int8>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .int8(buffer))
            return
        }
        if case .int8(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int8")
    }

    func appendInt16(_ value: Int16, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Int16>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .int16(buffer))
            return
        }
        if case .int16(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int16")
    }

    func appendInt32(_ value: Int32, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Int32>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .int32(buffer))
            return
        }
        if case .int32(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int32")
    }

    func appendInt64(_ value: Int64, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Int64>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .int64(buffer))
            return
        }
        if case .int64(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int64")
    }

    func appendUInt8(_ value: UInt8, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<UInt8>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .uint8(buffer))
            return
        }
        if case .uint8(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt8")
    }

    func appendUInt16(_ value: UInt16, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<UInt16>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .uint16(buffer))
            return
        }
        if case .uint16(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt16")
    }

    func appendUInt32(_ value: UInt32, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<UInt32>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .uint32(buffer))
            return
        }
        if case .uint32(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt32")
    }

    func appendUInt64(_ value: UInt64, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<UInt64>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .uint64(buffer))
            return
        }
        if case .uint64(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt64")
    }

    func appendFloat(_ value: Float, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Float>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .float32(buffer))
            return
        }
        if case .float32(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Float")
    }

    func appendDouble(_ value: Double, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Double>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .float64(buffer))
            return
        }
        if case .float64(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Double")
    }

    func appendNullableString(_ value: ClickHouseNullable<String>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<String>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableString(buffer))
            return
        }
        if case .nullableString(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "String?")
    }

    func appendNullableBool(_ value: ClickHouseNullable<Bool>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Bool>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableBool(buffer))
            return
        }
        if case .nullableBool(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Bool?")
    }

    func appendNullableInt8(_ value: ClickHouseNullable<Int8>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Int8>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableInt8(buffer))
            return
        }
        if case .nullableInt8(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int8?")
    }

    func appendNullableInt16(_ value: ClickHouseNullable<Int16>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Int16>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableInt16(buffer))
            return
        }
        if case .nullableInt16(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int16?")
    }

    func appendNullableInt32(_ value: ClickHouseNullable<Int32>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Int32>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableInt32(buffer))
            return
        }
        if case .nullableInt32(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int32?")
    }

    func appendNullableInt64(_ value: ClickHouseNullable<Int64>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Int64>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableInt64(buffer))
            return
        }
        if case .nullableInt64(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Int64?")
    }

    func appendNullableUInt8(_ value: ClickHouseNullable<UInt8>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<UInt8>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableUInt8(buffer))
            return
        }
        if case .nullableUInt8(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt8?")
    }

    func appendNullableUInt16(_ value: ClickHouseNullable<UInt16>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<UInt16>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableUInt16(buffer))
            return
        }
        if case .nullableUInt16(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt16?")
    }

    func appendNullableUInt32(_ value: ClickHouseNullable<UInt32>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<UInt32>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableUInt32(buffer))
            return
        }
        if case .nullableUInt32(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt32?")
    }

    func appendNullableUInt64(_ value: ClickHouseNullable<UInt64>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<UInt64>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableUInt64(buffer))
            return
        }
        if case .nullableUInt64(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UInt64?")
    }

    func appendNullableFloat(_ value: ClickHouseNullable<Float>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Float>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableFloat32(buffer))
            return
        }
        if case .nullableFloat32(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Float?")
    }

    func appendNullableDouble(_ value: ClickHouseNullable<Double>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Double>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableFloat64(buffer))
            return
        }
        if case .nullableFloat64(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Double?")
    }

    func appendDateTime(_ value: Date, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<Date>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .dateTime(buffer))
            return
        }
        if case .dateTime(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Date")
    }

    func appendNullableDateTime(_ value: ClickHouseNullable<Date>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<Date>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableDateTime(buffer))
            return
        }
        if case .nullableDateTime(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "Date?")
    }

    func appendUUID(_ value: UUID, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<UUID>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .uuid(buffer))
            return
        }
        if case .uuid(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UUID")
    }

    func appendNullableUUID(_ value: ClickHouseNullable<UUID>, forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<ClickHouseNullable<UUID>>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .nullableUUID(buffer))
            return
        }
        if case .nullableUUID(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "UUID?")
    }

    func appendMapStringString(_ value: [String: String], forColumn name: String) throws {
        let slot = try lookupSlot(name: name)
        if slot.isNew {
            let buffer = ClickHouseRowColumnBuffer<[String: String]>()
            buffer.values.append(value)
            installNewColumn(name: name, accumulator: .mapStringString(buffer))
            return
        }
        if case .mapStringString(let buffer) = columns[slot.index] {
            buffer.values.append(value)
            return
        }
        try throwMismatch(slotIndex: slot.index, columnName: name, conflicting: "[String: String]")
    }

    private struct SlotLookup {

        let index: Int
        let isNew: Bool

    }

    private func lookupSlot(name: String) throws -> SlotLookup {
        if schemaLocked, nextExpectedSlotIndex < columnNames.count,
           columnNames[nextExpectedSlotIndex] == name {
            let index = nextExpectedSlotIndex
            if currentRowIsInOrder {
                columnsTouchedCount += 1
                nextExpectedSlotIndex = index + 1
                return SlotLookup(index: index, isNew: false)
            }
            try markExistingSlotTouched(name: name, slotIndex: index)
            nextExpectedSlotIndex = index + 1
            return SlotLookup(index: index, isNew: false)
        }
        return try lookupSlotByDictionary(name: name)
    }

    private func lookupSlotByDictionary(name: String) throws -> SlotLookup {
        if currentRowIsInOrder, schemaLocked {
            replayInOrderPrefixIntoTouchMask()
            currentRowIsInOrder = false
        }
        if let existing = slotIndexByName[name] {
            try markExistingSlotTouched(name: name, slotIndex: existing)
            nextExpectedSlotIndex = existing + 1
            return SlotLookup(index: existing, isNew: false)
        }
        try rejectColumnIntroducedAfterFirstRow(name: name)
        return SlotLookup(index: columns.count, isNew: true)
    }

    private func replayInOrderPrefixIntoTouchMask() {
        let prefixCount = nextExpectedSlotIndex
        for index in 0..<prefixCount {
            columnsTouchedThisRow[index] = true
        }
    }

    private func markExistingSlotTouched(name: String, slotIndex: Int) throws {
        if slotIndex < columnsTouchedThisRow.count {
            try rejectDuplicateKey(name: name, slotIndex: slotIndex)
            columnsTouchedThisRow[slotIndex] = true
        } else {
            columnsTouchedThisRow.append(true)
        }
        columnsTouchedCount += 1
    }

    private func rejectDuplicateKey(name: String, slotIndex: Int) throws {
        guard columnsTouchedThisRow[slotIndex] else { return }
        throw ClickHouseError.rowEncoderUnsupportedType(
            swiftTypeDescription: "duplicate-key",
            columnName: name,
            message: "Column '\(name)' was encoded twice in the same row — this encoder requires each row's keys to appear exactly once."
        )
    }

    private func rejectColumnIntroducedAfterFirstRow(name: String) throws {
        guard schemaLocked else { return }
        throw ClickHouseError.rowEncoderColumnTypeMismatch(
            columnName: name,
            firstSeen: "absent in row 0",
            conflictingType: "introduced in row \(rowCount)",
            atRowIndex: rowCount
        )
    }

    private func installNewColumn(name: String, accumulator: ClickHouseRowColumnAccumulator) {
        let newIndex = columns.count
        columns.append(accumulator)
        columnNames.append(name)
        slotIndexByName[name] = newIndex
        columnsTouchedThisRow.append(true)
        columnsTouchedCount += 1
    }

    private func throwMismatch(slotIndex: Int, columnName: String, conflicting: String) throws -> Never {
        throw ClickHouseError.rowEncoderColumnTypeMismatch(
            columnName: columnName,
            firstSeen: columns[slotIndex].typeName,
            conflictingType: conflicting,
            atRowIndex: rowCount
        )
    }

}
