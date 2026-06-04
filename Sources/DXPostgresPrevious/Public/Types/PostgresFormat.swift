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

/// The wire encoding of a column's bytes. PostgreSQL sends every value either as
/// its human-readable text rendering or as a type-specific binary layout. The
/// simple query protocol always returns ``text``; the extended protocol returns
/// whichever format the client requested per column.
public enum PostgresFormat: Sendable, Equatable {

    case text
    case binary

    var code: Int16 {
        switch self {
        case .text: 0
        case .binary: 1
        }
    }

    static func from(code: Int16) throws(PostgresError) -> PostgresFormat {
        switch code {
        case 0: return .text
        case 1: return .binary
        default: throw PostgresError.protocolError(reason: "unknown column format code \(code)")
        }
    }
}
