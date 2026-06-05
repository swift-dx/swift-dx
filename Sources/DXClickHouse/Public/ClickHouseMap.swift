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

// A value destined for a ClickHouse Map(K, V) column. One Map value is
// the entries of a single row: `keys` carries each entry's key raw value
// bytes and `values` carries each entry's value raw value bytes, the two
// arrays parallel and equal length (one pair per entry). The key and
// value element-type discriminators describe the byte layout of those
// raw bytes (UTF-8 for String, little-endian for numeric scalars, the
// fixed-width content for FixedString). The wire layout matches
// Array(Tuple(K, V)): cumulative entry-count offsets, then the flattened
// keys in K format, then the flattened values in V format.
public struct ClickHouseMap: Sendable, Hashable, Codable {

    public let keyElement: ClickHouseArrayElementType
    public let valueElement: ClickHouseArrayElementType
    public let keys: [[UInt8]]
    public let values: [[UInt8]]

    public init(
        keyElement: ClickHouseArrayElementType,
        valueElement: ClickHouseArrayElementType,
        keys: [[UInt8]],
        values: [[UInt8]]
    ) {
        self.keyElement = keyElement
        self.valueElement = valueElement
        self.keys = keys
        self.values = values
    }

    public static func stringToUInt64(_ entries: [(String, UInt64)]) -> ClickHouseMap {
        ClickHouseMap(
            keyElement: .string,
            valueElement: .uint64,
            keys: entries.map { Array($0.0.utf8) },
            values: entries.map { littleEndianBytes($0.1) }
        )
    }

    public static func stringToString(_ entries: [(String, String)]) -> ClickHouseMap {
        ClickHouseMap(
            keyElement: .string,
            valueElement: .string,
            keys: entries.map { Array($0.0.utf8) },
            values: entries.map { Array($0.1.utf8) }
        )
    }

    public var stringKeys: [String] {
        keys.map { String(decoding: $0, as: UTF8.self) }
    }

    public var stringValues: [String] {
        values.map { String(decoding: $0, as: UTF8.self) }
    }

    // String-to-String view of a Map(String, String) row. A repeated key
    // keeps the last entry's value, matching how ClickHouse resolves a
    // duplicate Map key on read.
    public var stringDictionary: [String: String] {
        Dictionary(zip(stringKeys, stringValues), uniquingKeysWith: { _, latest in latest })
    }

    public func uint64Value(at entry: Int) -> UInt64 {
        readLittleEndian(values[entry])
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
