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

@testable import DXClickHouse
import Testing

// The INSERT statement's column list is generated from the row type's
// CodingKeys and wraps each name in backticks. A backtick (or backslash)
// inside the name must be backslash-escaped or the quoted identifier
// closes early and the whole statement is unparseable — and because the
// list is generated, the caller has no way to escape it themselves. This
// matches ClickHouse's own backQuote: ` -> \` and \ -> \\.
@Suite("Generated INSERT column names backslash-escape backticks")
struct ColumnNameEscapingTests {

    @Test("a backtick in the name is backslash-escaped")
    func escapesBacktick() {
        #expect(ClickHouseClient.escapeBacktickIdentifier("a`b") == "a\\`b")
    }

    @Test("a literal backslash in the name is backslash-escaped")
    func escapesBackslash() {
        #expect(ClickHouseClient.escapeBacktickIdentifier("a\\b") == "a\\\\b")
    }

    @Test("an ordinary name passes through unchanged")
    func ordinaryNameUnchanged() {
        #expect(ClickHouseClient.escapeBacktickIdentifier("created_at") == "created_at")
    }

    @Test("the generated column list keeps the backtick quoting well-formed")
    func columnListEscapesEmbeddedBacktick() {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .int32([])),
            ClickHouseNamedColumn(name: "we`ird", column: .string([])),
        ]
        let list = ClickHouseClient.makeColumnList(columns: columns)
        #expect(list == "(`id`, `we\\`ird`)")
    }

    @Test("an ordinary column list is unaffected")
    func ordinaryColumnListUnchanged() {
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .int32([])),
            ClickHouseNamedColumn(name: "name", column: .string([])),
        ]
        #expect(ClickHouseClient.makeColumnList(columns: columns) == "(`id`, `name`)")
    }
}
