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

// 256-bit signed integer column. Wire layout per row: 4 × UInt64 in
// little-endian order (32 bytes total). Used for `Int256` columns and
// for `Decimal256(scale)` columns (the same Int256 storage, different
// spec tag).
struct ClickHouseInt256Column: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    var values: [ClickHouseInt256]

    var rowCount: Int { values.count }

    func encode(into buffer: inout ByteBuffer) {
        let byteCount = values.count * 32
        buffer.reserveCapacity(minimumWritableBytes: byteCount)
        #if _endian(little)
        // Fast path: ClickHouseInt256 is four contiguous UInt64
        // limbs (limb0..limb3), so on a little-endian host its
        // in-memory layout matches the wire format. The MemoryLayout
        // check guards against a future field addition silently
        // turning this into a corrupt write.
        if MemoryLayout<ClickHouseInt256>.size == 32,
           MemoryLayout<ClickHouseInt256>.stride == 32 {
            values.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                let raw = UnsafeRawBufferPointer(start: base, count: byteCount)
                buffer.writeBytes(raw)
            }
            return
        }
        #endif
        for value in values {
            buffer.writeInteger(value.limb0, endianness: .little)
            buffer.writeInteger(value.limb1, endianness: .little)
            buffer.writeInteger(value.limb2, endianness: .little)
            buffer.writeInteger(value.limb3, endianness: .little)
        }
    }

    static func decode(spec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let needed = try requireInt256Capacity(rows: rows, available: buffer.readableBytes)
        #if _endian(little)
        if int256StorageIsContiguous32Bytes() {
            return decodeBulk(spec: spec, rows: rows, needed: needed, from: &buffer)
        }
        #endif
        return try decodeScalar(spec: spec, rows: rows, from: &buffer)
    }

    private static func requireInt256Capacity(rows: Int, available: Int) throws -> Int {
        let (needed, overflow) = rows.multipliedReportingOverflow(by: 32)
        guard !overflow, available >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: available
            )
        }
        return needed
    }

    private static func int256StorageIsContiguous32Bytes() -> Bool {
        MemoryLayout<ClickHouseInt256>.size == 32 && MemoryLayout<ClickHouseInt256>.stride == 32
    }

    private static func decodeBulk(spec: ClickHouseColumnSpec, rows: Int, needed: Int, from buffer: inout ByteBuffer) -> Self {
        var values = [ClickHouseInt256](
            repeating: ClickHouseInt256(limb0: 0, limb1: 0, limb2: 0, limb3: 0),
            count: rows
        )
        values.withUnsafeMutableBufferPointer { dst in
            let dstRaw = UnsafeMutableRawBufferPointer(dst)
            buffer.withUnsafeReadableBytes { src in
                dstRaw.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: needed))
            }
        }
        buffer.moveReaderIndex(forwardBy: needed)
        return Self(spec: spec, values: values)
    }

    private static func decodeScalar(spec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        var values: [ClickHouseInt256] = []
        values.reserveCapacity(rows)
        for _ in 0..<rows {
            values.append(try readInt256Row(from: &buffer))
        }
        return Self(spec: spec, values: values)
    }

    private static func readInt256Row(from buffer: inout ByteBuffer) throws -> ClickHouseInt256 {
        guard let limb0: UInt64 = buffer.readInteger(endianness: .little),
              let limb1: UInt64 = buffer.readInteger(endianness: .little),
              let limb2: UInt64 = buffer.readInteger(endianness: .little),
              let limb3: UInt64 = buffer.readInteger(endianness: .little) else {
            throw ClickHouseError.truncatedBuffer(needed: 32, available: buffer.readableBytes)
        }
        return ClickHouseInt256(limb0: limb0, limb1: limb1, limb2: limb2, limb3: limb3)
    }

}
