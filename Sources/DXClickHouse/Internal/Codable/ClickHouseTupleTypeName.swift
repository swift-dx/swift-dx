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

// Renders the inner element list of a ClickHouse Tuple(...) type name.
// An empty `names` array produces the anonymous form ("UInt64, String");
// a names array with one entry per column produces the named form
// ("a UInt64, b String") so the SELECT type the server returned round
// trips byte-for-byte through the encoder.
enum ClickHouseTupleTypeName {

    static func render(_ elements: [ClickHouseArrayElementType]) -> String {
        elements.map { $0.typeName }.joined(separator: ", ")
    }

    static func render(columns: [ClickHouseTypedColumn], names: [String]) -> String {
        if names.count == columns.count {
            return zipNamedElements(columns: columns, names: names).joined(separator: ", ")
        }
        return columns.map { $0.typeName }.joined(separator: ", ")
    }

    private static func zipNamedElements(columns: [ClickHouseTypedColumn], names: [String]) -> [String] {
        var rendered: [String] = []
        rendered.reserveCapacity(columns.count)
        for position in columns.indices {
            rendered.append("\(names[position]) \(columns[position].typeName)")
        }
        return rendered
    }
}
