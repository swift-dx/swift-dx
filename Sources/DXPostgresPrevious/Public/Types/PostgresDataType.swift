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

/// The classification of a column's PostgreSQL data type. Each case corresponds
/// to a built-in type's object identifier (OID) from the `pg_type` catalog. A
/// type DXPostgres does not name is carried as ``other(objectID:)`` with its raw
/// OID, so an unrecognized type is still inspectable rather than discarded.
public enum PostgresDataType: Sendable, Equatable {

    case bool
    case bytea
    case int2
    case int4
    case int8
    case objectIdentifier
    case float4
    case float8
    case numeric
    case text
    case varchar
    case bpchar
    case name
    case json
    case jsonb
    case uuid
    case date
    case time
    case timestamp
    case timestamptz
    case other(objectID: UInt32)
}
