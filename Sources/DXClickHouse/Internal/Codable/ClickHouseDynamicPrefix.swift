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

// Owns the Dynamic column body's structure prefix. The 8-byte structure
// serialization version selects the field layout that follows:
//
//   V1 (1): version, max-dynamic-types limit (uvarint), member count
//           (uvarint), member type-name strings. This is the shape
//           ClickHouse emits in a SELECT ... FORMAT Native response.
//   V2 (2): version, member count (uvarint), member type-name strings.
//           The max-dynamic-types field is dropped. This is the shape
//           ClickHouse expects when a client sends a Dynamic column on
//           the native INSERT path, so it is the shape the writer emits.
//
// The embedded Variant body (discriminator-mode prefix, discriminators,
// and sub-columns) follows this prefix and is serialized by the Variant
// code. The member type-name strings are in canonical sorted order.
enum ClickHouseDynamicPrefix {

    static let structureVersionV1: UInt64 = 1
    static let structureVersionV2: UInt64 = 2

    static func write(members: [ClickHouseArrayElementType], into output: inout [UInt8]) {
        ClickHouseWire.writeFixedInt(structureVersionV2, into: &output)
        ClickHouseWire.writeUVarInt(UInt64(members.count), into: &output)
        for member in members {
            ClickHouseWire.writeString(member.typeName, into: &output)
        }
    }
}
