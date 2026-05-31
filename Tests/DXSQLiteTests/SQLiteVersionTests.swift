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
import DXSQLite

@Suite("Vendored SQLite library version")
struct SQLiteVersionTests {

    @Test("vendored amalgamation reports 3.53.1")
    func reportsVendoredVersion() {
        let version = SQLiteVersion.current()
        #expect(version.text == "3.53.1")
        #expect(version.number == 3_053_001)
    }
}
