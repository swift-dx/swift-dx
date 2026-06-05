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

// One parsed result block presented column-by-column to the fast decode path
// (ClickHouseRowDecodable). A conforming type pulls each destination column's
// typed array out ONCE, then builds its rows in a tight loop over `count`.
// Extracting per column rather than per field per row is what lets the fast
// path approach a hand-written columnar loop — the per-row, per-field cursor
// it replaced re-extracted every column on every access.
//
// The block hides the package column representation behind typed extractors,
// so the public surface stays Swift-native. Each extractor throws if the bound
// column's type does not match; for a generated conformance that cannot occur.
public struct ClickHouseColumnBlock {

    package let columns: [ClickHouseTypedColumn]
    public let count: Int

    package init(columns: [ClickHouseTypedColumn], count: Int) {
        self.columns = columns
        self.count = count
    }

    public func uint64(_ field: Int) throws(ClickHouseError) -> [UInt64] {
        guard case .uint64(let values) = columns[field] else { throw Self.mismatch(field, "UInt64") }
        return values
    }

    public func int64(_ field: Int) throws(ClickHouseError) -> [Int64] {
        guard case .int64(let values) = columns[field] else { throw Self.mismatch(field, "Int64") }
        return values
    }

    public func uint32(_ field: Int) throws(ClickHouseError) -> [UInt32] {
        guard case .uint32(let values) = columns[field] else { throw Self.mismatch(field, "UInt32") }
        return values
    }

    public func int32(_ field: Int) throws(ClickHouseError) -> [Int32] {
        guard case .int32(let values) = columns[field] else { throw Self.mismatch(field, "Int32") }
        return values
    }

    public func uint16(_ field: Int) throws(ClickHouseError) -> [UInt16] {
        guard case .uint16(let values) = columns[field] else { throw Self.mismatch(field, "UInt16") }
        return values
    }

    public func int16(_ field: Int) throws(ClickHouseError) -> [Int16] {
        guard case .int16(let values) = columns[field] else { throw Self.mismatch(field, "Int16") }
        return values
    }

    public func uint8(_ field: Int) throws(ClickHouseError) -> [UInt8] {
        guard case .uint8(let values) = columns[field] else { throw Self.mismatch(field, "UInt8") }
        return values
    }

    public func int8(_ field: Int) throws(ClickHouseError) -> [Int8] {
        guard case .int8(let values) = columns[field] else { throw Self.mismatch(field, "Int8") }
        return values
    }

    public func double(_ field: Int) throws(ClickHouseError) -> [Double] {
        guard case .float64(let values) = columns[field] else { throw Self.mismatch(field, "Float64") }
        return values
    }

    public func float(_ field: Int) throws(ClickHouseError) -> [Float] {
        guard case .float32(let values) = columns[field] else { throw Self.mismatch(field, "Float32") }
        return values
    }

    public func bool(_ field: Int) throws(ClickHouseError) -> [Bool] {
        guard case .bool(let values) = columns[field] else { throw Self.mismatch(field, "Bool") }
        return values
    }

    public func strings(_ field: Int) throws(ClickHouseError) -> [String] {
        guard case .string(let values) = columns[field] else { throw Self.mismatch(field, "String") }
        return values.map { ClickHouseUTF8.decode($0) }
    }

    public func bytes(_ field: Int) throws(ClickHouseError) -> [[UInt8]] {
        guard case .string(let values) = columns[field] else { throw Self.mismatch(field, "String bytes") }
        return values
    }

    private static func mismatch(_ field: Int, _ expected: String) -> ClickHouseError {
        .protocolError(stage: "decoder.columnBlock", message: "column at field index \(field) is not \(expected)")
    }
}
