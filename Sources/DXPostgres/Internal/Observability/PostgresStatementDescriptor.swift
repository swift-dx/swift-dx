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
}
