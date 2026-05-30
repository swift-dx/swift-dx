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
        return (Int(columnCountRaw), Int(rowCountRaw), cursor - offset)
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
            if cursor >= limit { throw .needsMoreBytes(stage: "column header") }
            cursor += 1
        }
        return (name, type, cursor - offset)
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
