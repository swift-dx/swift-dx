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

// Server-emitted query profile, sent once at the end of a result
// stream just before EndOfStream. Carries the post-execution
// summary (rows, blocks, bytes scanned, limit accounting). When the
// negotiated revision is >= 54_469 the server also includes
// pre-aggregation row counts.
public struct ClickHouseProfileInfo: Sendable, Equatable {

    public let rows: UInt64
    public let blocks: UInt64
    public let bytes: UInt64
    public let appliedLimit: Bool
    public let rowsBeforeLimit: UInt64
    public let calculatedRowsBeforeLimit: Bool
    public let appliedAggregation: Bool
    public let rowsBeforeAggregation: UInt64

    public init(
        rows: UInt64,
        blocks: UInt64,
        bytes: UInt64,
        appliedLimit: Bool,
        rowsBeforeLimit: UInt64,
        calculatedRowsBeforeLimit: Bool,
        appliedAggregation: Bool = false,
        rowsBeforeAggregation: UInt64 = 0
    ) {
        self.rows = rows
        self.blocks = blocks
        self.bytes = bytes
        self.appliedLimit = appliedLimit
        self.rowsBeforeLimit = rowsBeforeLimit
        self.calculatedRowsBeforeLimit = calculatedRowsBeforeLimit
        self.appliedAggregation = appliedAggregation
        self.rowsBeforeAggregation = rowsBeforeAggregation
    }
}
