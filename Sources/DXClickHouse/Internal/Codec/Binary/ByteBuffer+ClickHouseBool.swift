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

private enum BulkBoolScan {

    case ok
    case invalid(rawByte: UInt8)

}

extension ByteBuffer {

    mutating func readClickHouseBool() throws -> Bool {
        guard let raw: UInt8 = readInteger() else {
            throw ClickHouseError.truncatedBuffer(needed: 1, available: readableBytes)
        }
        switch raw {
        case 0: return false
        case 1: return true
        default: throw ClickHouseError.invalidBoolean(rawValue: raw)
        }
    }

    mutating func writeClickHouseBool(_ value: Bool) {
        writeInteger(value ? UInt8(1) : UInt8(0))
    }

    mutating func readClickHouseBools(rows: Int) throws -> [Bool] {
        guard readableBytes >= rows else {
            throw ClickHouseError.truncatedBuffer(needed: rows, available: readableBytes)
        }
        // Bulk path: read each byte in one tight pointer-load loop and
        // validate it is 0 or 1. Avoids `rows` × readInteger() bounds
        // checks. Validation cannot be relaxed: the wire forbids any
        // byte other than 0/1 in a Bool column.
        var result = [Bool](repeating: false, count: rows)
        var scanOutcome: BulkBoolScan = .ok
        result.withUnsafeMutableBufferPointer { dst in
            withUnsafeReadableBytes { src in
                guard let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<rows {
                    let raw = srcBase[i]
                    switch raw {
                    case 0:
                        dst[i] = false
                    case 1:
                        dst[i] = true
                    default:
                        scanOutcome = .invalid(rawByte: raw)
                        return
                    }
                }
            }
        }
        if case .invalid(let raw) = scanOutcome {
            throw ClickHouseError.invalidBoolean(rawValue: raw)
        }
        moveReaderIndex(forwardBy: rows)
        return result
    }

    mutating func writeClickHouseBools(_ values: [Bool]) {
        // Bulk path: write the mask bytes directly into the buffer's
        // writable region instead of `count` × writeInteger calls.
        // Each writeInteger goes through a bounds check and writer
        // index update; the bulk path does one bounds check and a
        // tight pointer-store loop.
        let count = values.count
        writeWithUnsafeMutableBytes(minimumWritableBytes: count) { rawBytes in
            let dst = rawBytes.bindMemory(to: UInt8.self)
            for i in 0..<count {
                dst[i] = values[i] ? 1 : 0
            }
            return count
        }
    }

}
