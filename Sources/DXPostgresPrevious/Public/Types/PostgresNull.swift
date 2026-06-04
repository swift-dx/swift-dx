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

/// Binds a SQL NULL as a query parameter. Because parameters are concrete
/// ``PostgresEncodable`` values rather than optionals, NULL is expressed by
/// passing this type explicitly — `client.query("... $1 ...", binding: [PostgresNull()])`
/// — keeping "this parameter is null" a visible choice at the call site.
public struct PostgresNull: PostgresEncodable, Sendable {

    public init() {}

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        .sqlNull
    }
}
