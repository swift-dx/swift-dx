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

// BFloat16 column. Wire layout per row: UInt16 (the raw bit pattern)
// in little-endian order — 2 bytes per row.
struct ClickHouseBFloat16Column: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    var values: [ClickHouseBFloat16]

    var rowCount: Int { values.count }

    func encode(into buffer: inout ByteBuffer) {
        let byteCount = values.count * 2
        buffer.reserveCapacity(minimumWritableBytes: byteCount)
        #if _endian(little)
        // Fast path: ClickHouseBFloat16 is a single-field wrapper
        // over UInt16, so on a little-endian host its in-memory
        // layout matches the wire format. The MemoryLayout check
        // guards against a future field addition silently turning
        // this into a corrupt write.
        if MemoryLayout<ClickHouseBFloat16>.size == 2,
           MemoryLayout<ClickHouseBFloat16>.stride == 2 {
            values.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                let raw = UnsafeRawBufferPointer(start: base, count: byteCount)
                buffer.writeBytes(raw)
            }
            return
        }
        #endif
        for value in values {
            buffer.writeInteger(value.rawBits, endianness: .little)
        }
    }

    static func decode(spec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let needed = try requireBFloat16Capacity(rows: rows, available: buffer.readableBytes)
        #if _endian(little)
        if bfloat16StorageIsContiguous2Bytes() {
            return decodeBulk(spec: spec, rows: rows, needed: needed, from: &buffer)
        }
        #endif
        return try decodeScalar(spec: spec, rows: rows, from: &buffer)
    }

    private static func requireBFloat16Capacity(rows: Int, available: Int) throws -> Int {
        let (needed, overflow) = rows.multipliedReportingOverflow(by: 2)
        guard !overflow, available >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: available
            )
        }
        return needed
    }

    private static func bfloat16StorageIsContiguous2Bytes() -> Bool {
        MemoryLayout<ClickHouseBFloat16>.size == 2 && MemoryLayout<ClickHouseBFloat16>.stride == 2
    }

    private static func decodeBulk(spec: ClickHouseColumnSpec, rows: Int, needed: Int, from buffer: inout ByteBuffer) -> Self {
        var values = [ClickHouseBFloat16](
            repeating: ClickHouseBFloat16(rawBits: 0),
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
        var values: [ClickHouseBFloat16] = []
        values.reserveCapacity(rows)
        for _ in 0..<rows {
            guard let bits: UInt16 = buffer.readInteger(endianness: .little) else {
                throw ClickHouseError.truncatedBuffer(needed: 2, available: buffer.readableBytes)
            }
            values.append(ClickHouseBFloat16(rawBits: bits))
        }
        return Self(spec: spec, values: values)
    }

}
