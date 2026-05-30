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

// Server-side substitution parameter for a single query. Referenced in
// the SQL via the `{name:Type}` syntax that ClickHouse parses (e.g.
// `SELECT * FROM t WHERE id = {id:UInt64}`). The server validates the
// value against the declared type, providing SQL-injection-safe
// parameter substitution.
//
// The wire format reuses the Setting (name, flags, value) triple, but
// the flags field is always Custom (bit 1) for parameters.
public struct ClickHouseQueryParameter: Sendable, Equatable {

    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}
