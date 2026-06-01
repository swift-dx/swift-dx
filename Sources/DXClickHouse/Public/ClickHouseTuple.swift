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

// A value destined for a ClickHouse Tuple(...) column. One entry per
// tuple element, in element order: `elements` carries the per-position
// element type and `values` carries that position's raw value bytes for
// this row (UTF-8 for String, little-endian for numeric scalars, the
// fixed-width content for FixedString). The two arrays are parallel and
// must have equal length, which the static helpers guarantee. Element
// names are tuple metadata that the column type-name carries; they are
// not part of a row value and so are absent here.
public struct ClickHouseTuple: Sendable, Hashable, Codable {

    public let elements: [ClickHouseArrayElementType]
    public let values: [[UInt8]]

    public init(elements: [ClickHouseArrayElementType], values: [[UInt8]]) {
        self.elements = elements
        self.values = values
    }

    public static func uint64String(_ first: UInt64, _ second: String) -> ClickHouseTuple {
        ClickHouseTuple(
            elements: [.uint64, .string],
            values: [littleEndianBytes(first), Array(second.utf8)]
        )
    }

    public static func float64Pair(_ first: Double, _ second: Double) -> ClickHouseTuple {
        ClickHouseTuple(
            elements: [.float64, .float64],
            values: [littleEndianBytes(first.bitPattern), littleEndianBytes(second.bitPattern)]
        )
    }

    public static func point(longitude: Double, latitude: Double) -> ClickHouseTuple {
        float64Pair(longitude, latitude)
    }

    public var pointLongitude: Double {
        float64Element(at: 0)
    }

    public var pointLatitude: Double {
        float64Element(at: 1)
    }

    public var uint64FirstElement: UInt64 {
        readLittleEndian(values[0])
    }

    public var stringSecondElement: String {
        String(decoding: values[1], as: UTF8.self)
    }

    public func float64Element(at position: Int) -> Double {
        Double(bitPattern: readLittleEndian(values[position]))
    }

    private func readLittleEndian<T: FixedWidthInteger>(_ bytes: [UInt8]) -> T {
        var value: T = 0
        let width = MemoryLayout<T>.size
        for byteIndex in 0..<min(width, bytes.count) {
            value |= T(bytes[byteIndex]) << (8 * byteIndex)
        }
        return value
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }
}
