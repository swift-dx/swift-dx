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

import NIOCore

extension ByteBuffer {

    mutating func readClickHouseFloat32() throws -> Float32 {
        let bits = try readClickHouseFixedWidthInteger(UInt32.self)
        return Float32(bitPattern: bits)
    }

    mutating func readClickHouseFloat64() throws -> Float64 {
        let bits = try readClickHouseFixedWidthInteger(UInt64.self)
        return Float64(bitPattern: bits)
    }

    mutating func readClickHouseFloat32s(rows: Int) throws -> [Float32] {
        let elementSize = 4
        let (needed, overflow) = rows.multipliedReportingOverflow(by: elementSize)
        guard !overflow, readableBytes >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: readableBytes
            )
        }
        #if _endian(little)
        // Fast path: a Float32 on a little-endian host has the same
        // byte layout as the wire format (4-byte IEEE 754 little-endian).
        // Bulk-copy the readable region into the result array's
        // storage. Eliminates the intermediate [UInt32] allocation
        // and the N map() iterations through Float32(bitPattern:).
        var result = [Float32](repeating: 0, count: rows)
        result.withUnsafeMutableBufferPointer { dst in
            let dstRaw = UnsafeMutableRawBufferPointer(dst)
            withUnsafeReadableBytes { src in
                dstRaw.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: needed))
            }
        }
        moveReaderIndex(forwardBy: needed)
        return result
        #else
        let bits = try readClickHouseFixedWidthIntegers(UInt32.self, rows: rows)
        return bits.map(Float32.init(bitPattern:))
        #endif
    }

    mutating func readClickHouseFloat64s(rows: Int) throws -> [Float64] {
        let elementSize = 8
        let (needed, overflow) = rows.multipliedReportingOverflow(by: elementSize)
        guard !overflow, readableBytes >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: readableBytes
            )
        }
        #if _endian(little)
        var result = [Float64](repeating: 0, count: rows)
        result.withUnsafeMutableBufferPointer { dst in
            let dstRaw = UnsafeMutableRawBufferPointer(dst)
            withUnsafeReadableBytes { src in
                dstRaw.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: needed))
            }
        }
        moveReaderIndex(forwardBy: needed)
        return result
        #else
        let bits = try readClickHouseFixedWidthIntegers(UInt64.self, rows: rows)
        return bits.map(Float64.init(bitPattern:))
        #endif
    }

    mutating func writeClickHouseFloat32(_ value: Float32) {
        writeClickHouseFixedWidthInteger(value.bitPattern)
    }

    mutating func writeClickHouseFloat64(_ value: Float64) {
        writeClickHouseFixedWidthInteger(value.bitPattern)
    }

    mutating func writeClickHouseFloat32s(_ values: [Float32]) {
        let byteCount = values.count * 4
        reserveCapacity(minimumWritableBytes: byteCount)
        #if _endian(little)
        // Fast path: [Float32] storage on a little-endian host is
        // already the wire format — one bulk write replaces N
        // writeInteger calls.
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let raw = UnsafeRawBufferPointer(start: base, count: byteCount)
            writeBytes(raw)
        }
        #else
        for value in values {
            writeInteger(value.bitPattern, endianness: .little)
        }
        #endif
    }

    mutating func writeClickHouseFloat64s(_ values: [Float64]) {
        let byteCount = values.count * 8
        reserveCapacity(minimumWritableBytes: byteCount)
        #if _endian(little)
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let raw = UnsafeRawBufferPointer(start: base, count: byteCount)
            writeBytes(raw)
        }
        #else
        for value in values {
            writeInteger(value.bitPattern, endianness: .little)
        }
        #endif
    }

}
