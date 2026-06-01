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

/// A Swift value that can be bound as a parameter of an extended-protocol query.
/// Conformers render themselves into a ``PostgresCell`` in PostgreSQL's text
/// representation; the binding machinery sends every parameter in text format
/// and lets the server coerce it to the column's type. Returning
/// ``PostgresCell/sqlNull`` binds a SQL NULL.
public protocol PostgresEncodable: Sendable {

    func encodeToText() throws(PostgresError) -> PostgresCell
}
