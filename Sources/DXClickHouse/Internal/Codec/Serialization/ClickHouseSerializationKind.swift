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

// CH wraps a column's wire codec in one of several serialization kinds
// when `has_custom_serialization == true` is set on its block header.
// The kind byte (1 byte UInt8) immediately follows the customSer flag.
//
// Wire values mirror DB::ISerialization::Kind in the CH source. Only
// `default` and `sparse` reach the native protocol on read; the other
// kinds (DETACHED, REPLICATED, COMBINATION) exist for internal merge-
// tree storage and never appear in client-facing query results, so the
// reader rejects them rather than silently misframing.
enum ClickHouseSerializationKind: UInt8, Sendable {

    case `default` = 0
    case sparse = 1

    init(rawByte: UInt8) throws {
        guard let kind = ClickHouseSerializationKind(rawValue: rawByte) else {
            throw ClickHouseError.unknownSerializationKind(rawValue: rawByte)
        }
        self = kind
    }

}
