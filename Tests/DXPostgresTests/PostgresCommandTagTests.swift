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

import Testing
import DXPostgres

@Suite struct PostgresCommandTagTests {

    @Test func extractsAffectedRowsFromWriteTags() {
        #expect(PostgresCommandTag(raw: "INSERT 0 3").affectedRows == 3)
        #expect(PostgresCommandTag(raw: "UPDATE 5").affectedRows == 5)
        #expect(PostgresCommandTag(raw: "DELETE 2").affectedRows == 2)
        #expect(PostgresCommandTag(raw: "SELECT 10").affectedRows == 10)
        #expect(PostgresCommandTag(raw: "INSERT 0 0").affectedRows == 0)
    }

    @Test func returnsZeroForTagsWithoutACount() {
        #expect(PostgresCommandTag(raw: "CREATE TABLE").affectedRows == 0)
        #expect(PostgresCommandTag(raw: "BEGIN").affectedRows == 0)
        #expect(PostgresCommandTag(raw: "").affectedRows == 0)
    }

    @Test func exposesRawTagVerbatim() {
        let tag = PostgresCommandTag(raw: "INSERT 0 3")
        #expect(tag.raw == "INSERT 0 3")
        #expect(tag.description == "INSERT 0 3")
    }
}
