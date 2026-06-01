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

// Single source of truth for translating between a `ClickHouseVariantValue`
// and the (element type, raw little-endian bytes) pair that the wire
// layer serializes, and back. `ClickHouseArrayElementType` already owns
// the per-type byte width and type-name rendering, so a Variant member is
// expressed as one of those element types plus the row's raw value bytes.
enum ClickHouseVariantMember {

    // The member element type a non-null value belongs to. Returns
    // `.absent` for `.null` so the caller can assign the NULL discriminator.
    static func elementType(of value: ClickHouseVariantValue) -> ClickHouseNullable<ClickHouseArrayElementType> {
        switch value {
        case .null: .absent
        case .string: .present(.string)
        case .int64: .present(.int64)
        case .uint64: .present(.uint64)
        case .float64: .present(.float64)
        }
    }

    static func rawBytes(of value: ClickHouseVariantValue) -> [UInt8] {
        switch value {
        case .null: []
        case .string(let text): Array(text.utf8)
        case .int64(let number): littleEndianBytes(UInt64(bitPattern: number))
        case .uint64(let number): littleEndianBytes(number)
        case .float64(let number): littleEndianBytes(number.bitPattern)
        }
    }

    static func value(element: ClickHouseArrayElementType, bytes: [UInt8]) throws(ClickHouseError) -> ClickHouseVariantValue {
        switch element {
        case .string: return .string(String(decoding: bytes, as: UTF8.self))
        case .int64: return .int64(Int64(bitPattern: readLittleEndian(bytes)))
        case .uint64: return .uint64(readLittleEndian(bytes))
        case .float64: return .float64(Double(bitPattern: readLittleEndian(bytes)))
        default:
            throw .protocolError(
                stage: "variant.value",
                message: "Variant member type \(element.typeName) is not one of String, Int64, UInt64, Float64"
            )
        }
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func readLittleEndian(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<min(8, bytes.count) {
            value |= UInt64(bytes[byteIndex]) << (8 * byteIndex)
        }
        return value
    }
}
