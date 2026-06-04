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

/// Binds an `Encodable` value as a JSON parameter. The value is JSON-encoded and
/// sent as text, which the server coerces to a `json` or `jsonb` column — for
/// example `client.query("INSERT INTO docs (body) VALUES ($1)", binding: [PostgresJSON(order)])`.
/// On the read side, ``PostgresRow/decodeJSON(_:named:)`` reverses this.
public struct PostgresJSON<Value: Encodable & Sendable>: PostgresEncodable, Sendable {

    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        .bytes(try PostgresJSONCoding.encode(value))
    }
}
