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

import NIOCore

// ClickHouse `Nothing` type — empty type that holds no values. Used
// inside `Nullable(Nothing)` columns where every row is NULL (the
// inner column has rows but each row carries zero bytes), and as the
// type of expressions like `SELECT NULL FROM tbl`.
//
// Wire format: zero bytes per row. The column tracks rowCount only;
// encode is a no-op.
struct ClickHouseNothingColumn: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    let rowCount: Int

    func encode(into buffer: inout ByteBuffer) {
        // Nothing rows have no payload.
    }

    static func decode(spec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        // No bytes to consume — the row count is tracked externally.
        Self(spec: spec, rowCount: rows)
    }

}
