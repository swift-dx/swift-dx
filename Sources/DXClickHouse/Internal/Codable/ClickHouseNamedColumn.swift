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

// One named column in a block: the field name as it appears in the
// destination table (or the SELECT projection) plus the typed value
// buffer.
package struct ClickHouseNamedColumn: Sendable {

    package let name: String
    package let column: ClickHouseTypedColumn

    package init(name: String, column: ClickHouseTypedColumn) {
        self.name = name
        self.column = column
    }
}
