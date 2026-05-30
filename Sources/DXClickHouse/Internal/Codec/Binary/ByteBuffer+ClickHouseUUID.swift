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
import NIOCore

extension ByteBuffer {

    // ClickHouse stores UUIDs as two 64-bit integers in little-endian, where
    // each integer holds one half of the UUID interpreted as a big-endian
    // value. The net effect on the wire is that each 8-byte half of the
    // RFC 4122 byte sequence is reversed.
    mutating func readClickHouseUUID() throws -> UUID {
        let (high, low) = try readClickHouseUUIDHalves()
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { rawBytes in
            rawBytes.storeBytes(of: high.bigEndian, toByteOffset: 0, as: UInt64.self)
            rawBytes.storeBytes(of: low.bigEndian, toByteOffset: 8, as: UInt64.self)
        }
        return UUID(uuid: bytes)
    }

    private mutating func readClickHouseUUIDHalves() throws -> (high: UInt64, low: UInt64) {
        guard readableBytes >= 16 else {
            throw ClickHouseError.truncatedBuffer(needed: 16, available: readableBytes)
        }
        var high: UInt64 = 0
        var low: UInt64 = 0
        withUnsafeReadableBytes { raw in
            high = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
            low = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        moveReaderIndex(forwardBy: 16)
        return (high, low)
    }

    mutating func writeClickHouseUUID(_ uuid: UUID) {
        var local = uuid.uuid
        let parts = withUnsafeBytes(of: &local) { rawBytes -> (high: UInt64, low: UInt64) in
            let highMemory = rawBytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            let lowMemory = rawBytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            return (UInt64(bigEndian: highMemory), UInt64(bigEndian: lowMemory))
        }
        writeInteger(parts.high, endianness: .little)
        writeInteger(parts.low, endianness: .little)
    }

    mutating func readClickHouseUUIDs(rows: Int) throws -> [UUID] {
        // Use overflow-checked multiplication: a hostile `rows` value
        // close to `Int.max / 16` would otherwise trap the process
        // during `rows * 16`. Overflow surfaces as `truncatedBuffer`.
        let (needed, overflow) = rows.multipliedReportingOverflow(by: 16)
        try requireUUIDsBufferCapacity(needed: needed, overflow: overflow)
        #if _endian(little)
        if uuidStorageIsContiguous16Bytes() {
            return readClickHouseUUIDsBulk(rows: rows, needed: needed)
        }
        #endif
        return try readClickHouseUUIDsScalar(rows: rows)
    }

    private mutating func requireUUIDsBufferCapacity(needed: Int, overflow: Bool) throws {
        guard !overflow, readableBytes >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: readableBytes
            )
        }
    }

    private func uuidStorageIsContiguous16Bytes() -> Bool {
        MemoryLayout<UUID>.size == 16 && MemoryLayout<UUID>.stride == 16
    }

    private mutating func readClickHouseUUIDsBulk(rows: Int, needed: Int) -> [UUID] {
        let nilUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var result = [UUID](repeating: nilUUID, count: rows)
        result.withUnsafeMutableBufferPointer { dst in
            let dstRaw = UnsafeMutableRawBufferPointer(dst)
            withUnsafeReadableBytes { src in
                dstRaw.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: needed))
            }
            // Byte-reverse each 8-byte half. 2 halves per UUID.
            let halfCount = rows * 2
            for halfIndex in 0..<halfCount {
                let offset = halfIndex * 8
                let value = dstRaw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                dstRaw.storeBytes(of: value.byteSwapped, toByteOffset: offset, as: UInt64.self)
            }
        }
        moveReaderIndex(forwardBy: needed)
        return result
    }

    private mutating func readClickHouseUUIDsScalar(rows: Int) throws -> [UUID] {
        var result: [UUID] = []
        result.reserveCapacity(rows)
        for _ in 0..<rows {
            result.append(try readClickHouseUUID())
        }
        return result
    }

    mutating func writeClickHouseUUIDs(_ uuids: [UUID]) {
        let byteCount = uuids.count * 16
        reserveCapacity(minimumWritableBytes: byteCount)
        #if _endian(little)
        // Inverse of the bulk-read fast path. Build a temporary
        // contiguous byte buffer mirroring the input UUIDs, then
        // byte-reverse each 8-byte half — the wire format expects the
        // RFC-4122 bytes byte-reversed across each half. One bulk
        // writeBytes replaces N pairs of writeInteger calls.
        if MemoryLayout<UUID>.size == 16,
           MemoryLayout<UUID>.stride == 16 {
            var scratchBytes = [UInt8](repeating: 0, count: byteCount)
            scratchBytes.withUnsafeMutableBytes { scratchRaw in
                uuids.withUnsafeBufferPointer { src in
                    guard let base = src.baseAddress else { return }
                    let srcRaw = UnsafeRawBufferPointer(start: base, count: byteCount)
                    scratchRaw.copyMemory(from: srcRaw)
                    let halfCount = uuids.count * 2
                    for halfIndex in 0..<halfCount {
                        let offset = halfIndex * 8
                        let value = scratchRaw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                        scratchRaw.storeBytes(of: value.byteSwapped, toByteOffset: offset, as: UInt64.self)
                    }
                }
            }
            writeBytes(scratchBytes)
            return
        }
        #endif
        for uuid in uuids {
            writeClickHouseUUID(uuid)
        }
    }

}
