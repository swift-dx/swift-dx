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

/// The outcome of running one statement: the column descriptions, the decoded
/// rows, and the server's command tag. A statement that returns no result set
/// (an `INSERT` without `RETURNING`, a DDL command) yields an empty ``rows`` and
/// ``columns`` with a meaningful ``commandTag`` whose ``PostgresCommandTag/affectedRows``
/// reports how many rows it touched.
public struct PostgresQueryResult: Sendable {

    public let columns: [PostgresColumn]
    public let rows: [PostgresRow]
    public let commandTag: PostgresCommandTag

    public init(columns: [PostgresColumn], rows: [PostgresRow], commandTag: PostgresCommandTag) {
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
    }

    public var rowCount: Int {
        rows.count
    }

    public var isEmpty: Bool {
        rows.isEmpty
    }
}
