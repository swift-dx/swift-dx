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

// Owns the canonical ordering and rendering of Variant member types.
// ClickHouse normalizes a Variant type string by sorting its member type
// names alphabetically and assigns each member a discriminator equal to
// its position in that sorted order. The writer must reproduce that exact
// order so the discriminators it emits line up with the server's columns.
enum ClickHouseVariantTypeName {

    static func sorted(_ members: [ClickHouseArrayElementType]) -> [ClickHouseArrayElementType] {
        members.sorted { $0.typeName < $1.typeName }
    }

    static func render(_ members: [ClickHouseArrayElementType]) -> String {
        members.map { $0.typeName }.joined(separator: ", ")
    }
}
