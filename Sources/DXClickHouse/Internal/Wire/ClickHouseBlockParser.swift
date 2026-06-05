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

public enum ClickHouseBlockParser {

    // Parses BlockInfo + (columnCount, rowCount) prologue. Stops at the
    // first column-name byte. The caller then reads each column's
    // name + type + serialization flag + body interleaved (CH wire
    // order) via `parseColumnHeader` and a per-type body skipper.
    @inlinable
    public static func parsePrologue(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int
    ) throws(ClickHouseParseError) -> (columnCount: Int, rowCount: Int, consumed: Int) {
        var cursor = offset
        cursor += try skipBlockInfo(base: base, offset: cursor, limit: limit)
        let (columnCountRaw, columnBytes) = try ClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
        cursor += columnBytes
        let (rowCountRaw, rowBytes) = try ClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
        cursor += rowBytes
        // A malformed or hostile server can send a column or row count that
        // exceeds Int. The unchecked Int(UInt64) conversion would trap and
        // crash the process; reject it as malformed instead.
        let columnCount = try requireColumnCount(columnCountRaw)
        let rowCount = try requireRowCount(rowCountRaw)
        return (columnCount, rowCount, cursor - offset)
    }

    // The block reader reserves storage for `columnCount` entries before any
    // column header is read, so an in-Int but absurd count from a corrupt or
    // hostile header would drive a multi-gigabyte allocation and crash the
    // process. No real result block approaches this many columns.
    @usableFromInline
    static func requireColumnCount(_ raw: UInt64) throws(ClickHouseParseError) -> Int {
        guard let count = Int(exactly: raw) else {
            throw .malformed(stage: "prologue", message: "column count \(raw) exceeds Int range")
        }
        guard count <= 1 << 16 else {
            throw .malformed(stage: "prologue", message: "column count \(count) exceeds the per-block maximum of 65536")
        }
        return count
    }

    // The row count drives incremental, stream-bounded reads rather than an
    // up-front reservation, so it only needs the Int-range guard; large
    // result blocks are legitimate.
    @usableFromInline
    static func requireRowCount(_ raw: UInt64) throws(ClickHouseParseError) -> Int {
        guard let count = Int(exactly: raw) else {
            throw .malformed(stage: "prologue", message: "row count \(raw) exceeds Int range")
        }
        return count
    }

    // Reads a single column header: name, type, hasCustomSerialization.
    // Returns the parsed strings and the bytes consumed. Does NOT touch
    // the column body — the caller skips/decodes it based on `type`.
    @inlinable
    public static func parseColumnHeader(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int, revision: UInt64
    ) throws(ClickHouseParseError) -> (name: String, type: String, consumed: Int) {
        var cursor = offset
        let (name, nameBytes) = try ClickHouseWire.readString(base: base, offset: cursor, limit: limit)
        cursor += nameBytes
        let (type, typeBytes) = try ClickHouseWire.readString(base: base, offset: cursor, limit: limit)
        cursor += typeBytes
        if revision >= 54_454 {
            cursor += try requireDefaultColumnSerialization(base: base, offset: cursor, limit: limit, column: name)
        }
        return (name, type, cursor - offset)
    }

    @usableFromInline
    static func requireDefaultColumnSerialization(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int, column: String
    ) throws(ClickHouseParseError) -> Int {
        if offset >= limit { throw .needsMoreBytes(stage: "column header") }
        if base[offset] != 0 {
            throw .malformed(stage: "column header", message: "column '\(column)' uses custom (sparse) serialization, which this client does not support; wrap the column in materialize() to receive it in the default serialization")
        }
        return 1
    }

    @inlinable
    public static func skipBlockInfo(base: UnsafePointer<UInt8>, offset: Int, limit: Int) throws(ClickHouseParseError) -> Int {
        var cursor = offset
        while true {
            let (fieldNumber, fieldBytes) = try ClickHouseWire.readUVarInt(base: base, offset: cursor, limit: limit)
            cursor += fieldBytes
            switch fieldNumber {
            case 0:
                return cursor - offset
            case 1:
                cursor += try skipBlockInfoBool(cursor: cursor, limit: limit)
            case 2:
                cursor += try skipBlockInfoInt32(cursor: cursor, limit: limit)
            default:
                throw .malformed(stage: "block info", message: "unknown field \(fieldNumber)")
            }
        }
    }

    @inlinable
    static func skipBlockInfoBool(cursor: Int, limit: Int) throws(ClickHouseParseError) -> Int {
        if cursor >= limit { throw .needsMoreBytes(stage: "block info bool") }
        return 1
    }

    @inlinable
    static func skipBlockInfoInt32(cursor: Int, limit: Int) throws(ClickHouseParseError) -> Int {
        if cursor + 4 > limit { throw .needsMoreBytes(stage: "block info int32") }
        return 4
    }
}
