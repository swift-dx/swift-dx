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

// Renders an Enum8 / Enum16 name-to-value mapping into the exact inner
// form ClickHouse uses inside the column type, e.g. "'a' = 1, 'b' = 2".
// This is the inverse of the decoder's enum-mapping parser; both sides
// must agree on the canonical spacing and on escaping. Element names are
// ClickHouse string literals, so a literal backslash or single quote in
// the name is backslash-escaped to keep the type string well-formed
// (e.g. the name `can't` renders as `'can\'t'`).
enum ClickHouseEnumMapping {

    static func render(_ mapping: [ClickHouseEnumPair]) -> String {
        mapping.map { "'\(escapeName($0.name))' = \($0.value)" }.joined(separator: ", ")
    }

    static func escapeName(_ name: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(name.count + 2)
        for character in name {
            if needsBackslash(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func needsBackslash(_ character: Character) -> Bool {
        character == "\\" || character == "'"
    }
}
