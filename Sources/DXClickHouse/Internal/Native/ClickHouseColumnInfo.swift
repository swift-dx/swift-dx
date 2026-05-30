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

// One column's metadata as returned by `client.describe(table:database:)`.
// Wraps a subset of `system.columns` columns selected for the common
// schema-introspection use cases.
//
// `defaultKind` is one of "" (no default), "DEFAULT", "MATERIALIZED",
// "ALIAS", or "EPHEMERAL". `defaultExpression` carries the SQL
// expression text when `defaultKind` is non-empty. `comment` carries
// the comment string from the column's COMMENT clause (empty when
// none was set).
public struct ClickHouseColumnInfo: Sendable, Equatable, Decodable {

    public let name: String
    public let type: String
    public let defaultKind: String
    public let defaultExpression: String
    public let comment: String

    public init(
        name: String,
        type: String,
        defaultKind: String,
        defaultExpression: String,
        comment: String
    ) {
        self.name = name
        self.type = type
        self.defaultKind = defaultKind
        self.defaultExpression = defaultExpression
        self.comment = comment
    }

    private enum CodingKeys: String, CodingKey {

        case name
        case type
        case defaultKind = "default_kind"
        case defaultExpression = "default_expression"
        case comment

    }

}
