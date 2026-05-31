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

/// A read-only virtual table exposed to SQL, declared in ``SQLiteConfiguration``
/// and registered on every connection the database opens.
///
/// A provider surfaces Swift-computed rows as an eponymous table-valued source:
/// once registered under `name`, a query reads it directly as `SELECT * FROM
/// <name>` with no `CREATE VIRTUAL TABLE` step. `schema` is the column
/// declaration SQLite parses to learn the table's shape, written as a
/// `CREATE TABLE <name>(<columns>)` statement; only its column list is read.
/// `rows()` is invoked once at the start of each scan and the returned snapshot
/// is iterated to completion, so it must be cheap and self-consistent.
///
/// The provider is `Sendable` because the same value backs the writer
/// connection and every reader connection, each on its own thread.
public protocol SQLiteTableProvider: Sendable {

    var name: String { get }
    var schema: String { get }
    func rows() -> [[SQLiteValue]]
}
