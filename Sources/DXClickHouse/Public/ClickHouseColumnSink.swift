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

// Collects the columns of an INSERT block built through the columnar fast
// path (ClickHouseColumnarEncodable). A conforming type appends one typed
// array per column in a single pass over its rows, avoiding the per-row
// Codable encoding container. The sink hides the package column representation
// behind typed append methods, so the public surface stays Swift-native.
public struct ClickHouseColumnSink {

    package var columns: [ClickHouseNamedColumn] = []

    package init() {}

    public mutating func uint64(_ name: String, _ values: [UInt64]) { columns.append(.init(name: name, column: .uint64(values))) }
    public mutating func int64(_ name: String, _ values: [Int64]) { columns.append(.init(name: name, column: .int64(values))) }
    public mutating func uint32(_ name: String, _ values: [UInt32]) { columns.append(.init(name: name, column: .uint32(values))) }
    public mutating func int32(_ name: String, _ values: [Int32]) { columns.append(.init(name: name, column: .int32(values))) }
    public mutating func uint16(_ name: String, _ values: [UInt16]) { columns.append(.init(name: name, column: .uint16(values))) }
    public mutating func int16(_ name: String, _ values: [Int16]) { columns.append(.init(name: name, column: .int16(values))) }
    public mutating func uint8(_ name: String, _ values: [UInt8]) { columns.append(.init(name: name, column: .uint8(values))) }
    public mutating func int8(_ name: String, _ values: [Int8]) { columns.append(.init(name: name, column: .int8(values))) }
    public mutating func float(_ name: String, _ values: [Float]) { columns.append(.init(name: name, column: .float32(values))) }
    public mutating func double(_ name: String, _ values: [Double]) { columns.append(.init(name: name, column: .float64(values))) }
    public mutating func bool(_ name: String, _ values: [Bool]) { columns.append(.init(name: name, column: .bool(values))) }

    public mutating func string(_ name: String, _ values: [String]) {
        columns.append(.init(name: name, column: .stringValues(values)))
    }

    public mutating func bytes(_ name: String, _ values: [[UInt8]]) {
        columns.append(.init(name: name, column: .string(values)))
    }
}
