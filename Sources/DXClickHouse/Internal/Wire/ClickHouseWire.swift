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

// Inline wire-format parsing helpers operating directly on
// `UnsafePointer<UInt8>`. Every function takes a base pointer + offset +
// limit and returns the number of bytes consumed (or throws).
public enum ClickHouseWire {

    public static let uvarintMaxBytes = 10

    // Returns (value, consumedBytes). Throws `.needsMoreBytes` if the
    // limit is hit before the terminator bit, `.malformed` on >10-byte
    // overflows.
    @usableFromInline
    enum UvarintByteStep {
        case finalized(UInt64)
        case continuing
    }

    @inlinable
    public static func readUVarInt(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int
    ) throws(ClickHouseParseError) -> (UInt64, Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var byteIndex = 0
        while byteIndex < uvarintMaxBytes {
            let byte = try fetchUvarintByte(base: base, offset: offset, byteIndex: byteIndex, limit: limit)
            switch try absorbUvarintByte(byte, byteIndex: byteIndex, accumulator: value, shift: shift) {
            case .finalized(let finishedValue):
                return (finishedValue, byteIndex + 1)
            case .continuing:
                value |= UInt64(byte & 0x7F) << shift
                shift += 7
                byteIndex += 1
            }
        }
        throw .malformed(stage: "uvarint", message: "overflow")
    }

    @inlinable
    static func fetchUvarintByte(base: UnsafePointer<UInt8>, offset: Int, byteIndex: Int, limit: Int) throws(ClickHouseParseError) -> UInt8 {
        let position = offset + byteIndex
        if position >= limit { throw .needsMoreBytes(stage: "uvarint") }
        return base[position]
    }

    @inlinable
    static func absorbUvarintByte(_ byte: UInt8, byteIndex: Int, accumulator: UInt64, shift: UInt64) throws(ClickHouseParseError) -> UvarintByteStep {
        guard byte < 0x80 else { return .continuing }
        try guardUvarintTerminator(byteIndex: byteIndex, byte: byte)
        return .finalized(accumulator | (UInt64(byte) << shift))
    }

    @inlinable
    static func guardUvarintTerminator(byteIndex: Int, byte: UInt8) throws(ClickHouseParseError) {
        if byteIndex == uvarintMaxBytes - 1, byte > 1 {
            throw .malformed(stage: "uvarint", message: "overflow")
        }
    }

    // Reads a length-prefixed string and returns (utf8Slice, consumedBytes).
    // The returned slice references arena memory; copy out before recv().
    @inlinable
    public static func readStringSlice(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int,
        maxLength: Int = 1 << 30
    ) throws(ClickHouseParseError) -> (UnsafeBufferPointer<UInt8>, Int) {
        let (declared, lengthBytes) = try readUVarInt(base: base, offset: offset, limit: limit)
        if declared > UInt64(maxLength) {
            throw .malformed(stage: "string", message: "declared length \(declared) exceeds max \(maxLength)")
        }
        let payloadLength = Int(declared)
        let payloadOffset = offset + lengthBytes
        if payloadOffset + payloadLength > limit {
            throw .needsMoreBytes(stage: "string body")
        }
        let buffer = UnsafeBufferPointer(start: base + payloadOffset, count: payloadLength)
        return (buffer, lengthBytes + payloadLength)
    }

    @inlinable
    public static func readString(
        base: UnsafePointer<UInt8>, offset: Int, limit: Int,
        maxLength: Int = 1 << 30
    ) throws(ClickHouseParseError) -> (String, Int) {
        let (slice, consumed) = try readStringSlice(base: base, offset: offset, limit: limit, maxLength: maxLength)
        if slice.count == 0 { return ("", consumed) }
        let raw = UnsafeRawBufferPointer(slice)
        return (String(decoding: raw, as: Unicode.UTF8.self), consumed)
    }

    @inlinable
    public static func readFixedInt<T: FixedWidthInteger>(
        _ type: T.Type, base: UnsafePointer<UInt8>, offset: Int, limit: Int
    ) throws(ClickHouseParseError) -> (T, Int) {
        let size = MemoryLayout<T>.size
        if offset + size > limit { throw .needsMoreBytes(stage: "fixed int") }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: base + offset, count: size))
        }
        return (T(littleEndian: value), size)
    }

    // Encoder helpers. `output` must have enough capacity (10 bytes for
    // a UVarInt, length-prefix + bytes for a string).
    @inlinable
    public static func writeUVarInt(_ value: UInt64, into output: inout [UInt8]) {
        var remaining = value
        while remaining >= 0x80 {
            output.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        output.append(UInt8(remaining))
    }

    @inlinable
    public static func writeString(_ value: String, into output: inout [UInt8]) {
        let utf8 = Array(value.utf8)
        writeUVarInt(UInt64(utf8.count), into: &output)
        output.append(contentsOf: utf8)
    }

    @inlinable
    public static func writeFixedInt<T: FixedWidthInteger>(_ value: T, into output: inout [UInt8]) {
        let little = value.littleEndian
        withUnsafeBytes(of: little) { bytes in
            output.append(contentsOf: bytes)
        }
    }
}
