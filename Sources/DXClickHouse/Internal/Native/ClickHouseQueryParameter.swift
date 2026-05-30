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

// Server-side substitution parameter for a single query. Referenced
// in the SQL via the `{name:Type}` syntax that ClickHouse parses
// (e.g., `SELECT * FROM t WHERE id = {id:UInt64}`). The server
// validates the value against the declared type, providing
// SQL-injection-safe parameter substitution.
//
// Wire format is identical to `ClickHouseQuerySetting`'s, but the
// flags byte sets `Custom` (bit 1) instead of `Important` (bit 0).
// Decoding shares the Setting reader; only the flag interpretation
// differs.
public struct ClickHouseQueryParameter: Sendable, Equatable {

    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

}
