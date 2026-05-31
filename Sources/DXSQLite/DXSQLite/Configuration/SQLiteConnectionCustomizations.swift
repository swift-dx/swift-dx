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

// The per-connection extensions a database applies to every connection it opens
// (the writer and each pooled reader), so a query using a custom function or
// collation behaves identically wherever it runs.
struct SQLiteConnectionCustomizations: Sendable {

    let tuning: SQLiteTuning
    let authorization: SQLiteAuthorizationPolicy
    let functions: [SQLiteFunction]
    let aggregates: [SQLiteAggregate]
    let collations: [SQLiteCollation]
    let virtualTables: [any SQLiteTableProvider]
}
