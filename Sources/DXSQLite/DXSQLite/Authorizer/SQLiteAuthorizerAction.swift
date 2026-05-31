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

/// One action SQLite is about to take while compiling a statement, presented to
/// an authorizer for a verdict.
///
/// Each case carries only the operands SQLite supplies for that action: a table
/// and column for a `read`, a table for an `insert`, a pragma name and its
/// argument, and so on. A pragma with no argument carries an empty `argument`.
/// The authorizer is invoked once per action while a statement is prepared, so
/// a single `SELECT` joining two tables yields a `select` plus a `read` per
/// referenced column.
public enum SQLiteAuthorizerAction: Sendable, Equatable {

    case createIndex(index: String, table: String)
    case createTable(table: String)
    case createTemporaryIndex(index: String, table: String)
    case createTemporaryTable(table: String)
    case createTemporaryTrigger(trigger: String, table: String)
    case createTemporaryView(view: String)
    case createTrigger(trigger: String, table: String)
    case createView(view: String)
    case delete(table: String)
    case dropIndex(index: String, table: String)
    case dropTable(table: String)
    case dropTemporaryIndex(index: String, table: String)
    case dropTemporaryTable(table: String)
    case dropTemporaryTrigger(trigger: String, table: String)
    case dropTemporaryView(view: String)
    case dropTrigger(trigger: String, table: String)
    case dropView(view: String)
    case insert(table: String)
    case pragma(name: String, argument: String)
    case read(table: String, column: String)
    case select
    case transaction(operation: String)
    case update(table: String, column: String)
    case attach(file: String)
    case detach(database: String)
    case alterTable(database: String, table: String)
    case reindex(index: String)
    case analyze(table: String)
    case createVirtualTable(table: String, module: String)
    case dropVirtualTable(table: String, module: String)
    case function(name: String)
    case savepoint(operation: String, name: String)
    case recursive
}
