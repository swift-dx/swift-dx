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
// must agree on the canonical spacing.
enum ClickHouseEnumMapping {

    static func render(_ mapping: [ClickHouseEnumPair]) -> String {
        mapping.map { "'\($0.name)' = \($0.value)" }.joined(separator: ", ")
    }
}
