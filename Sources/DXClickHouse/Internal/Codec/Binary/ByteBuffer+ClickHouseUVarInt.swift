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

    static let clickhouseUVarIntMaxBytes = 10

    mutating func readClickHouseUVarInt() throws -> UInt64 {
        // Fast path: scan the readable region directly through a raw
        // pointer instead of calling readInteger() for every byte.
        // String length prefixes are nearly always 1-2 bytes (anything
        // under 16383), and per-byte readInteger has bounds-check +
        // loadUnaligned + readerIndex update overhead. Bulk-pointer
        // access amortizes that to one bounds check.
        let available = readableBytes
        guard available > 0 else {
            throw ClickHouseError.uvarintIncomplete
        }
        let scanLength = min(available, ByteBuffer.clickhouseUVarIntMaxBytes)
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var consumed = 0
        var done = false
        var overflow = false
        withUnsafeReadableBytes { rawBytes in
            guard let base = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while consumed < scanLength {
                let byte = base[consumed]
                consumed += 1
                if byte < 0x80 {
                    if consumed == ByteBuffer.clickhouseUVarIntMaxBytes, byte > 1 {
                        overflow = true
                        return
                    }
                    result |= UInt64(byte) << shift
                    done = true
                    return
                }
                result |= UInt64(byte & 0x7F) << shift
                shift += 7
            }
        }
        moveReaderIndex(forwardBy: consumed)
        return try Self.finishUVarInt(result: result, consumed: consumed, done: done, overflow: overflow)
    }

    private static func finishUVarInt(result: UInt64, consumed: Int, done: Bool, overflow: Bool) throws -> UInt64 {
        if done { return result }
        throw truncatedOrOverflowError(consumed: consumed, overflow: overflow)
    }

    private static func truncatedOrOverflowError(consumed: Int, overflow: Bool) -> ClickHouseError {
        if overflow || consumed == ByteBuffer.clickhouseUVarIntMaxBytes {
            return .uvarintOverflow
        }
        return .uvarintIncomplete
    }

    mutating func writeClickHouseUVarInt(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            writeInteger(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        writeInteger(UInt8(remaining))
    }

}
