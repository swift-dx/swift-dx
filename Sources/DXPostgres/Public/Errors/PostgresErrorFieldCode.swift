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

/// The optional fields a PostgreSQL `ErrorResponse`/`NoticeResponse` may carry
/// beyond the always-present severity, SQLSTATE code, and primary message. Each
/// raw value is the single-byte field-type marker the wire protocol assigns to
/// that field. Query a server error for one of these with
/// ``PostgresServerError/value(of:)``, which returns ``PostgresFieldValue`` so an
/// absent field is a named state rather than a null.
public enum PostgresErrorFieldCode: UInt8, Sendable, Equatable, CaseIterable {

    case detail = 0x44
    case hint = 0x48
    case position = 0x50
    case internalPosition = 0x70
    case internalQuery = 0x71
    case context = 0x57
    case schemaName = 0x73
    case tableName = 0x74
    case columnName = 0x63
    case dataTypeName = 0x64
    case constraintName = 0x6e
    case file = 0x46
    case line = 0x4c
    case routine = 0x52
}
