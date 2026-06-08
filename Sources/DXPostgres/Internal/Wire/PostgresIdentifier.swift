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

// Renders a SQL identifier (schema, table, or column name) as a double-quoted
// token with any embedded double quote doubled, so the name is always parsed as a
// single identifier and can never be read as SQL syntax. The one owner of
// identifier quoting: statement interpolation and the startup search-path both
// route through here so the two never drift.
enum PostgresIdentifier {

    static func quoted(_ name: String) -> String {
        var result = "\""
        for character in name {
            if character == "\"" { result += "\"\"" } else { result.append(character) }
        }
        result += "\""
        return result
    }
}
