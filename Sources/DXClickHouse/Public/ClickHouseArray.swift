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

// A value destined for a ClickHouse Array(inner) column. Each element is
// held as its raw value bytes (UTF-8 for String, the fixed-width content
// for FixedString, little-endian for numeric scalars); the static helpers
// build those bytes for the common element types. The element-type
// discriminator must match the byte layout, which the helpers guarantee.
public struct ClickHouseArray: Sendable, Hashable, Codable {

    public let element: ClickHouseArrayElementType
    public let elements: [[UInt8]]

    public init(element: ClickHouseArrayElementType, elements: [[UInt8]]) {
        self.element = element
        self.elements = elements
    }

    public static func strings(_ values: [String]) -> ClickHouseArray {
        ClickHouseArray(element: .string, elements: values.map { Array($0.utf8) })
    }

    public static func fixedStrings(_ values: [[UInt8]], length: Int) -> ClickHouseArray {
        ClickHouseArray(element: .fixedString(length: length), elements: values)
    }

    public static func int32s(_ values: [Int32]) -> ClickHouseArray {
        ClickHouseArray(element: .int32, elements: values.map { littleEndianBytes($0) })
    }

    public static func int64s(_ values: [Int64]) -> ClickHouseArray {
        ClickHouseArray(element: .int64, elements: values.map { littleEndianBytes($0) })
    }

    public static func uint64s(_ values: [UInt64]) -> ClickHouseArray {
        ClickHouseArray(element: .uint64, elements: values.map { littleEndianBytes($0) })
    }

    public static func float64s(_ values: [Double]) -> ClickHouseArray {
        ClickHouseArray(element: .float64, elements: values.map { littleEndianBytes($0.bitPattern) })
    }

    public static func bools(_ values: [Bool]) -> ClickHouseArray {
        ClickHouseArray(element: .bool, elements: values.map { [$0 ? 1 : 0] })
    }

    public var strings: [String] {
        elements.map { String(decoding: $0, as: UTF8.self) }
    }

    public var bools: [Bool] {
        elements.map { ($0.first ?? 0) != 0 }
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }
}
