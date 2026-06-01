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

// A value destined for a ClickHouse Array(Tuple(A, B)) column, the shape
// a Nested(...) sub-column collapses to when the server keeps it as a
// single column (flatten_nested = 0). One value is one row: `firstValues`
// carries each tuple's first-position raw value bytes and `secondValues`
// carries each tuple's second-position raw value bytes, the two arrays
// parallel and equal length (one pair per tuple element in this row). The
// element-type discriminators describe the byte layout of those raw bytes
// (UTF-8 for String, little-endian for numeric scalars, the fixed-width
// content for FixedString). The wire layout matches Map(A, B): cumulative
// tuple-count offsets, then the flattened first column in A format, then
// the flattened second column in B format.
//
// flatten_nested caveat: with ClickHouse's default flatten_nested = 1, a
// Nested(a A, b B) column is reported on SELECT as two separate columns
// `n.a Array(A)` and `n.b Array(B)`, each a plain Array handled by
// ClickHouseArray. Set flatten_nested = 0 (session or column) to keep the
// single Array(Tuple(A, B)) column this type round-trips.
public struct ClickHouseArrayOfTuple: Sendable, Hashable, Codable {

    public let firstElement: ClickHouseArrayElementType
    public let secondElement: ClickHouseArrayElementType
    public let firstValues: [[UInt8]]
    public let secondValues: [[UInt8]]

    public init(
        firstElement: ClickHouseArrayElementType,
        secondElement: ClickHouseArrayElementType,
        firstValues: [[UInt8]],
        secondValues: [[UInt8]]
    ) {
        self.firstElement = firstElement
        self.secondElement = secondElement
        self.firstValues = firstValues
        self.secondValues = secondValues
    }

    public static func uint64String(_ entries: [(UInt64, String)]) -> ClickHouseArrayOfTuple {
        ClickHouseArrayOfTuple(
            firstElement: .uint64,
            secondElement: .string,
            firstValues: entries.map { littleEndianBytes($0.0) },
            secondValues: entries.map { Array($0.1.utf8) }
        )
    }

    public static func float64Pairs(_ entries: [(Double, Double)]) -> ClickHouseArrayOfTuple {
        ClickHouseArrayOfTuple(
            firstElement: .float64,
            secondElement: .float64,
            firstValues: entries.map { littleEndianBytes($0.0.bitPattern) },
            secondValues: entries.map { littleEndianBytes($0.1.bitPattern) }
        )
    }

    public static func ring(points: [(longitude: Double, latitude: Double)]) -> ClickHouseArrayOfTuple {
        float64Pairs(points.map { ($0.longitude, $0.latitude) })
    }

    public func uint64First(at element: Int) -> UInt64 {
        readLittleEndian(firstValues[element])
    }

    public func stringSecond(at element: Int) -> String {
        String(decoding: secondValues[element], as: UTF8.self)
    }

    public func float64First(at element: Int) -> Double {
        Double(bitPattern: readLittleEndian(firstValues[element]))
    }

    public func float64Second(at element: Int) -> Double {
        Double(bitPattern: readLittleEndian(secondValues[element]))
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
