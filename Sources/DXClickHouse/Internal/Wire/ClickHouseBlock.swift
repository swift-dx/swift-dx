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

// Result of parsing a single Data-block body: a row count + a column
// metadata list. The body bytes themselves remain in the arena; the
// caller can re-read them through `ClickHouseConnection.lastBlockBytes`
// if it wants to walk columns inline, or just consume the row count.
public struct ClickHouseBlock {

    public let rowCount: Int
    public let columnCount: Int
    public let columnNames: [String]
    public let columnTypes: [String]
    public let bodyStart: Int
    public let bodyLength: Int

    public init(rowCount: Int, columnCount: Int, columnNames: [String], columnTypes: [String], bodyStart: Int, bodyLength: Int) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.columnNames = columnNames
        self.columnTypes = columnTypes
        self.bodyStart = bodyStart
        self.bodyLength = bodyLength
    }
}
