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

    func appendDateTime64(_ ticks: Int64, precision: UInt8, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .dateTime64(precision: precision)) { $0.appendDateTime64(ticks) }
    }

    func appendFixedString(_ bytes: [UInt8], length: Int, forColumn name: String) throws(ClickHouseError) {
        let padded = try Self.padToFixedWidth(bytes, length: length, column: name)
        try append(name: name, kind: .fixedString(length: length)) { $0.appendFixedString(padded) }
    }

    private static func padToFixedWidth(_ bytes: [UInt8], length: Int, column: String) throws(ClickHouseError) -> [UInt8] {
        if bytes.count > length {
            throw .protocolError(
                stage: "encoder.fixedString",
                message: "column '\(column)' value is \(bytes.count) bytes, exceeds FixedString(\(length))"
            )
        }
        var padded = bytes
        if padded.count < length {
            padded.append(contentsOf: repeatElement(0, count: length - padded.count))
        }
        return padded
    }

    func appendLowCardinality(_ value: [UInt8], inner: ClickHouseLowCardinalityInner, forColumn name: String) throws(ClickHouseError) {
        let normalized = try Self.normalizeLowCardinalityValue(value, inner: inner, column: name)
        try append(name: name, kind: .lowCardinality(inner: inner)) { $0.appendLowCardinality(normalized) }
    }

    func appendArray(_ elements: [[UInt8]], element: ClickHouseArrayElementType, forColumn name: String) throws(ClickHouseError) {
        let normalized = try Self.normalizeArrayElements(elements, element: element, column: name)
        try append(name: name, kind: .array(element: element)) { $0.appendArray(normalized) }
    }

    private static func normalizeArrayElements(_ elements: [[UInt8]], element: ClickHouseArrayElementType, column: String) throws(ClickHouseError) -> [[UInt8]] {
        guard case .fixedString(let length) = element else { return elements }
        var normalized: [[UInt8]] = []
        normalized.reserveCapacity(elements.count)
        for value in elements {
            normalized.append(try padToFixedWidth(value, length: length, column: column))
        }
        return normalized
    }

    func appendTuple(_ values: [[UInt8]], elements: [ClickHouseArrayElementType], forColumn name: String) throws(ClickHouseError) {
        let normalized = try Self.normalizeTupleValues(values, elements: elements, column: name)
        try append(name: name, kind: .tuple(elements: elements)) { $0.appendTuple(normalized) }
    }

    private static func normalizeTupleValues(_ values: [[UInt8]], elements: [ClickHouseArrayElementType], column: String) throws(ClickHouseError) -> [[UInt8]] {
        if values.count != elements.count {
            throw .protocolError(
                stage: "encoder.tuple",
                message: "column '\(column)' Tuple value has \(values.count) elements, expected \(elements.count)"
            )
        }
        var normalized: [[UInt8]] = []
        normalized.reserveCapacity(elements.count)
        for position in elements.indices {
            normalized.append(try normalizeTupleElement(values[position], element: elements[position], column: column))
        }
        return normalized
    }

    private static func normalizeTupleElement(_ value: [UInt8], element: ClickHouseArrayElementType, column: String) throws(ClickHouseError) -> [UInt8] {
        guard case .fixedString(let length) = element else { return value }
        return try padToFixedWidth(value, length: length, column: column)
    }

    func appendMap(keys: [[UInt8]], values: [[UInt8]], keyElement: ClickHouseArrayElementType, valueElement: ClickHouseArrayElementType, forColumn name: String) throws(ClickHouseError) {
        try Self.requireEqualEntryCount(keys: keys, values: values, column: name)
        let normalizedKeys = try Self.normalizeArrayElements(keys, element: keyElement, column: name)
        let normalizedValues = try Self.normalizeArrayElements(values, element: valueElement, column: name)
        try append(name: name, kind: .map(keyElement: keyElement, valueElement: valueElement)) {
            $0.appendMap(keys: normalizedKeys, values: normalizedValues)
        }
    }

    private static func requireEqualEntryCount(keys: [[UInt8]], values: [[UInt8]], column: String) throws(ClickHouseError) {
        if keys.count != values.count {
            throw .protocolError(
                stage: "encoder.map",
                message: "column '\(column)' Map has \(keys.count) keys but \(values.count) values; each entry needs one key and one value"
            )
        }
    }

    func appendArrayOfTuple(firstValues: [[UInt8]], secondValues: [[UInt8]], firstElement: ClickHouseArrayElementType, secondElement: ClickHouseArrayElementType, forColumn name: String) throws(ClickHouseError) {
        try Self.requirePairedTupleElements(firstValues: firstValues, secondValues: secondValues, column: name)
        let normalizedFirst = try Self.normalizeArrayElements(firstValues, element: firstElement, column: name)
        let normalizedSecond = try Self.normalizeArrayElements(secondValues, element: secondElement, column: name)
        try append(name: name, kind: .arrayOfTuple(firstElement: firstElement, secondElement: secondElement)) {
            $0.appendArrayOfTuple(firstValues: normalizedFirst, secondValues: normalizedSecond)
        }
    }

    private static func requirePairedTupleElements(firstValues: [[UInt8]], secondValues: [[UInt8]], column: String) throws(ClickHouseError) {
        if firstValues.count != secondValues.count {
            throw .protocolError(
                stage: "encoder.arrayOfTuple",
                message: "column '\(column)' Array(Tuple) has \(firstValues.count) first-position values but \(secondValues.count) second-position values; each tuple needs one value per position"
            )
        }
    }

    func appendVariant(members: [ClickHouseArrayElementType], value: ClickHouseVariantValue, forColumn name: String) throws(ClickHouseError) {
        let sortedMembers = ClickHouseVariantTypeName.sorted(members)
        let resolved = try Self.resolveVariantRow(members: sortedMembers, value: value, column: name)
        try append(name: name, kind: .variant(members: sortedMembers)) {
            $0.appendVariant(discriminator: resolved.discriminator, bytes: resolved.bytes)
        }
    }

    private static func resolveVariantRow(members: [ClickHouseArrayElementType], value: ClickHouseVariantValue, column: String) throws(ClickHouseError) -> (discriminator: UInt8, bytes: [UInt8]) {
        guard case .present(let element) = ClickHouseVariantMember.elementType(of: value) else {
            return (255, [])
        }
        let index = try memberIndex(of: element, in: members, column: column)
        return (index, ClickHouseVariantMember.rawBytes(of: value))
    }

    private static func memberIndex(of element: ClickHouseArrayElementType, in members: [ClickHouseArrayElementType], column: String) throws(ClickHouseError) -> UInt8 {
        guard let index = members.firstIndex(of: element) else {
            throw .protocolError(
                stage: "encoder.variant",
                message: "column '\(column)' Variant value of type \(element.typeName) is not declared in members \(ClickHouseVariantTypeName.render(members))"
            )
        }
        guard index <= 254 else {
            throw .protocolError(
                stage: "encoder.variant",
                message: "column '\(column)' Variant has more than 255 members; basic-discriminator serialization supports at most 255"
            )
        }
        return UInt8(index)
    }

    func appendDynamic(value: ClickHouseVariantValue, forColumn name: String) throws(ClickHouseError) {
        let element = ClickHouseVariantMember.elementType(of: value)
        let bytes = ClickHouseVariantMember.rawBytes(of: value)
        try append(name: name, kind: .dynamic) {
            $0.appendDynamic(element: element, bytes: bytes)
        }
    }

    func appendAggregateState(signature: String, bytes: [UInt8], forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .aggregateFunction(signature: signature)) { $0.appendAggregateState(bytes) }
    }

    func appendDate32(_ days: Int32, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .date32) { $0.appendDate32(days) }
    }

    func appendBFloat16(_ rawBits: UInt16, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .bfloat16) { $0.appendBFloat16(rawBits) }
    }

    func appendDate(_ days: UInt16, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .date) { $0.appendDate(days) }
    }

    func appendTime(_ seconds: Int32, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .time) { $0.appendTime(seconds) }
    }

    func appendTime64(_ ticks: Int64, precision: UInt8, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .time64(precision: precision)) { $0.appendTime64(ticks) }
    }

    func appendIPv4(_ raw: UInt32, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .ipv4) { $0.appendIPv4(raw) }
    }

    func appendIPv6(_ bytes: [UInt8], forColumn name: String) throws(ClickHouseError) {
        let normalized = try Self.padToFixedWidth(bytes, length: 16, column: name)
        try append(name: name, kind: .ipv6) { $0.appendIPv6(normalized) }
    }

    func appendInt128(_ value: Int128, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .int128) { $0.appendInt128(value) }
    }

    func appendUInt128(_ value: UInt128, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .uint128) { $0.appendUInt128(value) }
    }

    func appendInt256(_ value: ClickHouseInt256, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .int256) { $0.appendInt256(value) }
    }

    func appendJSON(_ bytes: [UInt8], forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .json) { $0.appendJSON(bytes) }
    }

    func appendUInt256(_ value: ClickHouseUInt256, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .uint256) { $0.appendUInt256(value) }
    }

    func appendDecimal(_ value: ClickHouseDecimal, precision: UInt8, scale: UInt8, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .decimal(precision: precision, scale: scale)) { $0.appendDecimal(value) }
    }

    func appendInterval(_ value: Int64, kind: ClickHouseIntervalKind, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .interval(kind: kind)) { $0.appendInterval(value) }
    }

    func appendNullableInterval(_ value: ClickHouseNullable<Int64>, kind: ClickHouseIntervalKind, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .interval(kind: kind), value: value) { slot, present in
            slot.appendInterval(present)
        } sentinel: { slot in
            slot.appendInterval(0)
        }
    }

    private static func normalizeLowCardinalityValue(_ value: [UInt8], inner: ClickHouseLowCardinalityInner, column: String) throws(ClickHouseError) -> [UInt8] {
        switch inner {
        case .string: return value
        case .fixedString(let length): return try padToFixedWidth(value, length: length, column: column)
        }
    }

    func appendEnum8(_ value: Int8, mapping: [ClickHouseEnumPair], forColumn name: String) throws(ClickHouseError) {
        try Self.requireValidEnumNames(mapping, column: name)
        try append(name: name, kind: .enum8(mapping: mapping)) { $0.appendEnum8(value) }
    }

    func appendEnum16(_ value: Int16, mapping: [ClickHouseEnumPair], forColumn name: String) throws(ClickHouseError) {
        try Self.requireValidEnumNames(mapping, column: name)
        try append(name: name, kind: .enum16(mapping: mapping)) { $0.appendEnum16(value) }
    }

    private static func requireValidEnumNames(_ mapping: [ClickHouseEnumPair], column: String) throws(ClickHouseError) {
        if mapping.isEmpty {
            throw .protocolError(stage: "encoder.enum", message: "column '\(column)' has an empty Enum mapping")
        }
        for pair in mapping {
            try requireValidEnumName(pair.name, column: column)
        }
    }

    private static func requireValidEnumName(_ name: String, column: String) throws(ClickHouseError) {
        if name.isEmpty {
            throw .protocolError(stage: "encoder.enum", message: "column '\(column)' has an empty Enum name")
        }
        if name.contains(where: { $0 == "'" || $0 == "," || $0 == "\\" }) {
            throw .protocolError(stage: "encoder.enum", message: "column '\(column)' Enum name '\(name)' must not contain quotes, commas, or backslashes")
        }
    }

    func appendNullableUUID(_ value: ClickHouseNullable<UUID>, forColumn name: String) throws(ClickHouseError) {
        try append(name: name, kind: .nullableUUID) { $0.appendNullableUUID(value) }
    }

    func appendNullableDateTime64(_ value: ClickHouseNullable<ClickHouseDateTime64>, precision: UInt8, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .dateTime64(precision: precision), value: value) { slot, present in
            slot.appendDateTime64(present.ticks)
        } sentinel: { slot in
            slot.appendDateTime64(0)
        }
    }

    func appendNullableFixedString(_ value: ClickHouseNullable<[UInt8]>, length: Int, forColumn name: String) throws(ClickHouseError) {
        let normalized = try Self.normalizeNullableFixedString(value, length: length, column: name)
        try appendNullable(name: name, inner: .fixedString(length: length), value: normalized) { slot, present in
            slot.appendFixedString(present)
        } sentinel: { slot in
            slot.appendFixedString([UInt8](repeating: 0, count: length))
        }
    }

    private static func normalizeNullableFixedString(_ value: ClickHouseNullable<[UInt8]>, length: Int, column: String) throws(ClickHouseError) -> ClickHouseNullable<[UInt8]> {
        switch value {
        case .absent: return .absent
        case .present(let bytes): return .present(try padToFixedWidth(bytes, length: length, column: column))
        }
    }

    func appendNullableEnum8(_ value: ClickHouseNullable<Int8>, mapping: [ClickHouseEnumPair], forColumn name: String) throws(ClickHouseError) {
        try Self.requireValidEnumNames(mapping, column: name)
        try appendNullable(name: name, inner: .enum8(mapping: mapping), value: value) { slot, present in
            slot.appendEnum8(present)
        } sentinel: { slot in
            slot.appendEnum8(0)
        }
    }

    func appendNullableEnum16(_ value: ClickHouseNullable<Int16>, mapping: [ClickHouseEnumPair], forColumn name: String) throws(ClickHouseError) {
        try Self.requireValidEnumNames(mapping, column: name)
        try appendNullable(name: name, inner: .enum16(mapping: mapping), value: value) { slot, present in
            slot.appendEnum16(present)
        } sentinel: { slot in
            slot.appendEnum16(0)
        }
    }

    func appendNullableDate32(_ value: ClickHouseNullable<Int32>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .date32, value: value) { slot, present in
            slot.appendDate32(present)
        } sentinel: { slot in
            slot.appendDate32(0)
        }
    }

    func appendNullableDate(_ value: ClickHouseNullable<UInt16>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .date, value: value) { slot, present in
            slot.appendDate(present)
        } sentinel: { slot in
            slot.appendDate(0)
        }
    }

    func appendNullableTime(_ value: ClickHouseNullable<Int32>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .time, value: value) { slot, present in
            slot.appendTime(present)
        } sentinel: { slot in
            slot.appendTime(0)
        }
    }

    func appendNullableTime64(_ value: ClickHouseNullable<ClickHouseTime64>, precision: UInt8, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .time64(precision: precision), value: value) { slot, present in
            slot.appendTime64(present.ticks)
        } sentinel: { slot in
            slot.appendTime64(0)
        }
    }

    func appendNullableIPv4(_ value: ClickHouseNullable<UInt32>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .ipv4, value: value) { slot, present in
            slot.appendIPv4(present)
        } sentinel: { slot in
            slot.appendIPv4(0)
        }
    }

    func appendNullableIPv6(_ value: ClickHouseNullable<[UInt8]>, forColumn name: String) throws(ClickHouseError) {
        let normalized = try Self.normalizeNullableFixedString(value, length: 16, column: name)
        try appendNullable(name: name, inner: .ipv6, value: normalized) { slot, present in
            slot.appendIPv6(present)
        } sentinel: { slot in
            slot.appendIPv6([UInt8](repeating: 0, count: 16))
        }
    }

    func appendNullableInt128(_ value: ClickHouseNullable<Int128>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .int128, value: value) { slot, present in
            slot.appendInt128(present)
        } sentinel: { slot in
            slot.appendInt128(0)
        }
    }

    func appendNullableUInt128(_ value: ClickHouseNullable<UInt128>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .uint128, value: value) { slot, present in
            slot.appendUInt128(present)
        } sentinel: { slot in
            slot.appendUInt128(0)
        }
    }

    func appendNullableInt256(_ value: ClickHouseNullable<ClickHouseInt256>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .int256, value: value) { slot, present in
            slot.appendInt256(present)
        } sentinel: { slot in
            slot.appendInt256(ClickHouseInt256(0))
        }
    }

    func appendNullableUInt256(_ value: ClickHouseNullable<ClickHouseUInt256>, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .uint256, value: value) { slot, present in
            slot.appendUInt256(present)
        } sentinel: { slot in
            slot.appendUInt256(ClickHouseUInt256(0))
        }
    }

    func appendNullableDecimal(_ value: ClickHouseNullable<ClickHouseDecimal>, precision: UInt8, scale: UInt8, forColumn name: String) throws(ClickHouseError) {
        try appendNullable(name: name, inner: .decimal(precision: precision, scale: scale), value: value) { slot, present in
            slot.appendDecimal(present)
        } sentinel: { slot in
            slot.appendDecimal(ClickHouseDecimal(limb0: 0, limb1: 0, limb2: 0, limb3: 0, precision: precision, scale: scale))
        }
    }

    func appendAbsentNullable(forColumn name: String) throws(ClickHouseError) {
        guard let existing = columnIndexByName[name] else {
            throw .protocolError(
                stage: "encoder.appendAbsentNullable",
                message: "column '\(name)' is NULL on its first encoded row; a Nullable wrapper column must carry its type on the first row that defines the column set"
            )
        }
        guard case .nullable(let inner) = columns[existing].kind else {
            throw .protocolError(
                stage: "encoder.appendAbsentNullable",
                message: "column '\(name)' received a NULL value but was declared non-Nullable as \(columns[existing].kind)"
            )
        }
        let slot = columns[existing]
        slot.appendMask(true)
        slot.appendSentinel(of: inner)
        touched[existing] = true
    }

    private func appendNullable<Wrapped>(
        name: String,
        inner: SlotKind,
        value: ClickHouseNullable<Wrapped>,
        present: @escaping (Slot, Wrapped) -> Void,
        sentinel: @escaping (Slot) -> Void
    ) throws(ClickHouseError) {
        try append(name: name, kind: .nullable(inner: inner)) { slot in
            switch value {
            case .present(let wrapped):
                slot.appendMask(false)
                present(slot, wrapped)
            case .absent:
                slot.appendMask(true)
                sentinel(slot)
            }
        }
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
    case dateTime64(precision: UInt8)
    case date
    case time
    case time64(precision: UInt8)
    case fixedString(length: Int)
    case enum8(mapping: [ClickHouseEnumPair])
    case enum16(mapping: [ClickHouseEnumPair])
    case lowCardinality(inner: ClickHouseLowCardinalityInner)
    case array(element: ClickHouseArrayElementType)
    case date32
    case bfloat16
    case ipv4
    case ipv6
    case int128
    case uint128
    case int256
    case uint256
    case json
    case decimal(precision: UInt8, scale: UInt8)
    case interval(kind: ClickHouseIntervalKind)
    case tuple(elements: [ClickHouseArrayElementType])
    case map(keyElement: ClickHouseArrayElementType, valueElement: ClickHouseArrayElementType)
    case arrayOfTuple(firstElement: ClickHouseArrayElementType, secondElement: ClickHouseArrayElementType)
    case variant(members: [ClickHouseArrayElementType])
    case dynamic
    case aggregateFunction(signature: String)
    indirect case nullable(inner: SlotKind)

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
        case .dateTime64(let precision): "DateTime64(\(precision))"
        case .date: "Date"
        case .time: "Time"
        case .time64(let precision): "Time64(\(precision))"
        case .fixedString(let length): "FixedString(\(length))"
        case .enum8(let mapping): "Enum8(\(ClickHouseEnumMapping.render(mapping)))"
        case .enum16(let mapping): "Enum16(\(ClickHouseEnumMapping.render(mapping)))"
        case .lowCardinality(let inner): "LowCardinality(\(inner.typeName))"
        case .array(let element): "Array(\(element.typeName))"
        case .date32: "Date32"
        case .bfloat16: "BFloat16"
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        case .int128: "Int128"
        case .uint128: "UInt128"
        case .int256: "Int256"
        case .uint256: "UInt256"
        case .json: "String"
        case .decimal(let precision, let scale): "Decimal(\(precision), \(scale))"
        case .interval(let kind): kind.typeName
        case .tuple(let elements): "Tuple(\(ClickHouseTupleTypeName.render(elements)))"
        case .map(let keyElement, let valueElement): "Map(\(keyElement.typeName), \(valueElement.typeName))"
        case .arrayOfTuple(let firstElement, let secondElement): "Array(Tuple(\(firstElement.typeName), \(secondElement.typeName)))"
        case .variant(let members): "Variant(\(ClickHouseVariantTypeName.render(members)))"
        case .dynamic: "Dynamic"
        case .aggregateFunction(let signature): "AggregateFunction(\(signature))"
        case .nullable(let inner): "Nullable(\(inner.description))"
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
    private var dateTime64Values: [Int64] = []
    private var dateValues: [UInt16] = []
    private var timeValues: [Int32] = []
    private var time64Values: [Int64] = []
    private var fixedStringValues: [[UInt8]] = []
    private var enum8Values: [Int8] = []
    private var enum16Values: [Int16] = []
    private var lowCardinalityValues: [[UInt8]] = []
    private var arrayValues: [[[UInt8]]] = []
    private var tupleValues: [[[UInt8]]] = []
    private var mapKeys: [[[UInt8]]] = []
    private var mapValues: [[[UInt8]]] = []
    private var arrayOfTupleFirst: [[[UInt8]]] = []
    private var arrayOfTupleSecond: [[[UInt8]]] = []
    private var variantDiscriminators: [UInt8] = []
    private var variantValues: [[UInt8]] = []
    private var dynamicElements: [ClickHouseNullable<ClickHouseArrayElementType>] = []
    private var dynamicValues: [[UInt8]] = []
    private var aggregateStates: [[UInt8]] = []
    private var date32Values: [Int32] = []
    private var bfloat16Values: [UInt16] = []
    private var ipv4Values: [UInt32] = []
    private var ipv6Values: [[UInt8]] = []
    private var int128Values: [Int128] = []
    private var uint128Values: [UInt128] = []
    private var int256Values: [ClickHouseInt256] = []
    private var uint256Values: [ClickHouseUInt256] = []
    private var jsonValues: [[UInt8]] = []
    private var decimalValues: [ClickHouseDecimal] = []
    private var intervalValues: [Int64] = []
    private var nullableMask: [Bool] = []

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
    func appendDateTime64(_ value: Int64) { dateTime64Values.append(value) }
    func appendDate(_ value: UInt16) { dateValues.append(value) }
    func appendTime(_ value: Int32) { timeValues.append(value) }
    func appendTime64(_ value: Int64) { time64Values.append(value) }
    func appendFixedString(_ value: [UInt8]) { fixedStringValues.append(value) }
    func appendEnum8(_ value: Int8) { enum8Values.append(value) }
    func appendEnum16(_ value: Int16) { enum16Values.append(value) }
    func appendLowCardinality(_ value: [UInt8]) { lowCardinalityValues.append(value) }
    func appendArray(_ value: [[UInt8]]) { arrayValues.append(value) }
    func appendTuple(_ value: [[UInt8]]) { tupleValues.append(value) }
    func appendMap(keys: [[UInt8]], values: [[UInt8]]) { mapKeys.append(keys); mapValues.append(values) }
    func appendArrayOfTuple(firstValues: [[UInt8]], secondValues: [[UInt8]]) { arrayOfTupleFirst.append(firstValues); arrayOfTupleSecond.append(secondValues) }
    func appendVariant(discriminator: UInt8, bytes: [UInt8]) { variantDiscriminators.append(discriminator); variantValues.append(bytes) }
    func appendDynamic(element: ClickHouseNullable<ClickHouseArrayElementType>, bytes: [UInt8]) { dynamicElements.append(element); dynamicValues.append(bytes) }
    func appendAggregateState(_ bytes: [UInt8]) { aggregateStates.append(bytes) }
    func appendDate32(_ value: Int32) { date32Values.append(value) }
    func appendBFloat16(_ value: UInt16) { bfloat16Values.append(value) }
    func appendIPv4(_ value: UInt32) { ipv4Values.append(value) }
    func appendIPv6(_ value: [UInt8]) { ipv6Values.append(value) }
    func appendInt128(_ value: Int128) { int128Values.append(value) }
    func appendUInt128(_ value: UInt128) { uint128Values.append(value) }
    func appendInt256(_ value: ClickHouseInt256) { int256Values.append(value) }
    func appendUInt256(_ value: ClickHouseUInt256) { uint256Values.append(value) }
    func appendJSON(_ value: [UInt8]) { jsonValues.append(value) }
    func appendDecimal(_ value: ClickHouseDecimal) { decimalValues.append(value) }
    func appendInterval(_ value: Int64) { intervalValues.append(value) }
    func appendMask(_ isNull: Bool) { nullableMask.append(isNull) }

    func appendSentinel(of inner: SlotKind) {
        switch inner {
        case .dateTime64: appendDateTime64(0)
        case .date: appendDate(0)
        case .time: appendTime(0)
        case .time64: appendTime64(0)
        case .fixedString(let length): appendFixedString([UInt8](repeating: 0, count: length))
        case .enum8: appendEnum8(0)
        case .enum16: appendEnum16(0)
        case .date32: appendDate32(0)
        case .bfloat16: appendBFloat16(0)
        case .ipv4: appendIPv4(0)
        case .ipv6: appendIPv6([UInt8](repeating: 0, count: 16))
        case .int128: appendInt128(0)
        case .uint128: appendUInt128(0)
        case .int256: appendInt256(ClickHouseInt256(0))
        case .uint256: appendUInt256(ClickHouseUInt256(0))
        case .decimal(let precision, let scale):
            appendDecimal(ClickHouseDecimal(limb0: 0, limb1: 0, limb2: 0, limb3: 0, precision: precision, scale: scale))
        case .interval: appendInterval(0)
        default: appendDate32(0)
        }
    }

    func snapshot() -> ClickHouseTypedColumn {
        snapshot(of: kind)
    }

    private func snapshot(of kind: SlotKind) -> ClickHouseTypedColumn {
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
        case .dateTime64(let precision): .dateTime64(dateTime64Values, precision: precision)
        case .date: .date(dateValues)
        case .time: .time(timeValues)
        case .time64(let precision): .time64(time64Values, precision: precision)
        case .fixedString(let length): .fixedString(fixedStringValues, length: length)
        case .enum8(let mapping): .enum8(enum8Values, mapping: mapping)
        case .enum16(let mapping): .enum16(enum16Values, mapping: mapping)
        case .lowCardinality(let inner): .lowCardinality(lowCardinalityValues, inner: inner)
        case .array(let element): .array(arrayValues, element: element)
        case .tuple(let elements): .tuple(ClickHouseTupleColumnBuilder.columns(rows: tupleValues, elements: elements), names: [])
        case .map(let keyElement, let valueElement): .map(keys: mapKeys, values: mapValues, keyElement: keyElement, valueElement: valueElement)
        case .arrayOfTuple(let firstElement, let secondElement): .arrayOfTuple(firstValues: arrayOfTupleFirst, secondValues: arrayOfTupleSecond, firstElement: firstElement, secondElement: secondElement)
        case .variant(let members): .variant(members: members, discriminators: variantDiscriminators, values: variantValues)
        case .dynamic: ClickHouseDynamicColumnBuilder.column(elements: dynamicElements, values: dynamicValues)
        case .aggregateFunction(let signature): .aggregateFunction(signature: signature, states: aggregateStates)
        case .date32: .date32(date32Values)
        case .bfloat16: .bfloat16(bfloat16Values)
        case .ipv4: .ipv4(ipv4Values)
        case .ipv6: .ipv6(ipv6Values)
        case .int128: .int128(int128Values)
        case .uint128: .uint128(uint128Values)
        case .int256: .int256(int256Values)
        case .uint256: .uint256(uint256Values)
        case .json: .json(jsonValues)
        case .decimal(let precision, let scale): .decimal(decimalValues, precision: precision, scale: scale)
        case .interval(let kind): .interval(intervalValues, kind: kind)
        case .nullable(let inner): .nullable(mask: nullableMask, inner: snapshot(of: inner))
        }
    }
}
