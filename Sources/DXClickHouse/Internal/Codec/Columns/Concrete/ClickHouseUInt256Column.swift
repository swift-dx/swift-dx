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

// 256-bit unsigned integer column. Wire layout per row: 4 × UInt64 in
// little-endian order (32 bytes total). Same wire layout as
// `ClickHouseInt256Column`; the type distinction signals signed vs
// unsigned interpretation.
struct ClickHouseUInt256Column: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    var values: [ClickHouseUInt256]

    var rowCount: Int { values.count }

    func encode(into buffer: inout ByteBuffer) {
        let byteCount = values.count * 32
        buffer.reserveCapacity(minimumWritableBytes: byteCount)
        #if _endian(little)
        if MemoryLayout<ClickHouseUInt256>.size == 32,
           MemoryLayout<ClickHouseUInt256>.stride == 32 {
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
        let needed = try requireUInt256Capacity(rows: rows, available: buffer.readableBytes)
        #if _endian(little)
        if uint256StorageIsContiguous32Bytes() {
            return decodeBulk(spec: spec, rows: rows, needed: needed, from: &buffer)
        }
        #endif
        return try decodeScalar(spec: spec, rows: rows, from: &buffer)
    }

    private static func requireUInt256Capacity(rows: Int, available: Int) throws -> Int {
        let (needed, overflow) = rows.multipliedReportingOverflow(by: 32)
        guard !overflow, available >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: available
            )
        }
        return needed
    }

    private static func uint256StorageIsContiguous32Bytes() -> Bool {
        MemoryLayout<ClickHouseUInt256>.size == 32 && MemoryLayout<ClickHouseUInt256>.stride == 32
    }

    private static func decodeBulk(spec: ClickHouseColumnSpec, rows: Int, needed: Int, from buffer: inout ByteBuffer) -> Self {
        var values = [ClickHouseUInt256](
            repeating: ClickHouseUInt256(limb0: 0, limb1: 0, limb2: 0, limb3: 0),
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
        var values: [ClickHouseUInt256] = []
        values.reserveCapacity(rows)
        for _ in 0..<rows {
            values.append(try readUInt256Row(from: &buffer))
        }
        return Self(spec: spec, values: values)
    }

    private static func readUInt256Row(from buffer: inout ByteBuffer) throws -> ClickHouseUInt256 {
        guard let limb0: UInt64 = buffer.readInteger(endianness: .little),
              let limb1: UInt64 = buffer.readInteger(endianness: .little),
              let limb2: UInt64 = buffer.readInteger(endianness: .little),
              let limb3: UInt64 = buffer.readInteger(endianness: .little) else {
            throw ClickHouseError.truncatedBuffer(needed: 32, available: buffer.readableBytes)
        }
        return ClickHouseUInt256(limb0: limb0, limb1: limb1, limb2: limb2, limb3: limb3)
    }

}
