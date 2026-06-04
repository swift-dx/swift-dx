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

// Derives the operation label (SELECT, INSERT, UPDATE, ...) from a SQL string:
// the leading whitespace-delimited token uppercased, or "QUERY" when there is no
// token. Called lazily on the hot path — only when a log entry is actually
// emitted or a span is recording — so the statement is never scanned otherwise.
enum PostgresStatementDescriptor {

    private static let separators: Set<Character> = [" ", "\n", "\t", "\r"]

    static func operation(of statement: String) -> String {
        for token in statement.split(whereSeparator: { separators.contains($0) }) {
            return token.uppercased()
        }
        return "QUERY"
    }

    // Leading keywords whose statements have no persistent effect, so replaying one
    // after an ambiguous connection failure cannot double-apply anything. The set is
    // deliberately conservative: anything not listed — INSERT, UPDATE, DELETE,
    // MERGE, CALL, DO, COPY, every DDL verb, a data-modifying WITH, and EXPLAIN
    // (because EXPLAIN ANALYZE executes its target) — is treated as a write and is
    // never retried once it may have reached the server.
    private static let readOnlyOperations: Set<String> = ["SELECT", "SHOW", "TABLE", "VALUES", "FETCH"]

    static func isReadOnly(_ statement: String) -> Bool {
        readOnlyOperations.contains(operation(of: statement))
    }
}
