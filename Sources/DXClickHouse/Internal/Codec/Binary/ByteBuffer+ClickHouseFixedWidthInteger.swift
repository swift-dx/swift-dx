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

    mutating func readClickHouseFixedWidthInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let value: T = readInteger(endianness: .little) else {
            throw ClickHouseError.truncatedBuffer(
                needed: MemoryLayout<T>.size,
                available: readableBytes
            )
        }
        return value
    }

    mutating func readClickHouseFixedWidthIntegers<T: FixedWidthInteger>(_ type: T.Type, rows: Int) throws -> [T] {
        let elementSize = MemoryLayout<T>.size
        let (needed, overflow) = rows.multipliedReportingOverflow(by: elementSize)
        try requireFixedWidthIntegerCapacity(needed: needed, overflow: overflow)
        #if _endian(little)
        return readFixedWidthIntegersBulk(rows: rows, needed: needed)
        #else
        return try readFixedWidthIntegersScalar(rows: rows, elementSize: elementSize)
        #endif
    }

    private mutating func requireFixedWidthIntegerCapacity(needed: Int, overflow: Bool) throws {
        guard !overflow, readableBytes >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: readableBytes
            )
        }
    }

    private mutating func readFixedWidthIntegersBulk<T: FixedWidthInteger>(rows: Int, needed: Int) -> [T] {
        // Skip the default-init memset by allocating an uninitialised
        // [T] buffer and overwriting every byte via the wire memcpy.
        // Every byte is written before the array becomes observable so
        // the contract on Array.init(unsafeUninitializedCapacity:) is
        // satisfied. On a 100k-row UInt64 column this avoids ~800 KB
        // of redundant memset before the memcpy overwrites it.
        let result = [T](unsafeUninitializedCapacity: rows) { buffer, initialized in
            withUnsafeReadableBytes { src in
                let dstRaw = UnsafeMutableRawBufferPointer(buffer)
                dstRaw.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: needed))
            }
            initialized = rows
        }
        moveReaderIndex(forwardBy: needed)
        return result
    }

    private mutating func readFixedWidthIntegersScalar<T: FixedWidthInteger>(rows: Int, elementSize: Int) throws -> [T] {
        var result: [T] = []
        result.reserveCapacity(rows)
        for _ in 0..<rows {
            guard let value: T = readInteger(endianness: .little) else {
                throw ClickHouseError.truncatedBuffer(needed: elementSize, available: readableBytes)
            }
            result.append(value)
        }
        return result
    }

    mutating func writeClickHouseFixedWidthInteger<T: FixedWidthInteger>(_ value: T) {
        writeInteger(value, endianness: .little)
    }

    mutating func writeClickHouseFixedWidthIntegers<T: FixedWidthInteger>(_ values: [T]) {
        let byteCount = values.count * MemoryLayout<T>.size
        reserveCapacity(minimumWritableBytes: byteCount)
        #if _endian(little)
        // Fast path: a Swift array of fixed-width integers on a
        // little-endian host is already laid out identically to the
        // wire format. One bulk write replaces N writeInteger calls.
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let raw = UnsafeRawBufferPointer(start: base, count: byteCount)
            writeBytes(raw)
        }
        #else
        for value in values {
            writeInteger(value, endianness: .little)
        }
        #endif
    }

}
