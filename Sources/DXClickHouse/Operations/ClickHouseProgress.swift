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

// Server-emitted progress snapshot during query execution. ClickHouse
// emits Progress packets repeatedly (typically every ~250ms for
// non-trivial queries). Each packet reports the INCREMENTAL rows and
// bytes processed since the last update, plus the running estimate of
// `totalRows` (which may grow as the server discovers more parts to
// scan). On revision >= 54_420 the packet also carries write counters
// for INSERTs; on revision >= 54_460 it carries `elapsedNanoseconds`.
// Older servers omit those fields and the corresponding properties
// stay at zero.
//
// Production observability pattern: accumulate `rows` across callback
// firings to track total processed; compare to `totalRows` for an
// estimated completion fraction.
public struct ClickHouseProgress: Sendable, Equatable {

    public let rows: UInt64
    public let bytes: UInt64
    public let totalRows: UInt64
    public let totalBytes: UInt64
    public let writtenRows: UInt64
    public let writtenBytes: UInt64
    public let elapsedNanoseconds: UInt64

    public init(
        rows: UInt64,
        bytes: UInt64,
        totalRows: UInt64,
        totalBytes: UInt64 = 0,
        writtenRows: UInt64 = 0,
        writtenBytes: UInt64 = 0,
        elapsedNanoseconds: UInt64 = 0
    ) {
        self.rows = rows
        self.bytes = bytes
        self.totalRows = totalRows
        self.totalBytes = totalBytes
        self.writtenRows = writtenRows
        self.writtenBytes = writtenBytes
        self.elapsedNanoseconds = elapsedNanoseconds
    }
}

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

// Server-emitted per-block ProfileEvents (packet type=14). Carries a
// table name plus one Block of counter rows. The raw transport's
// callback only surfaces the table name; the block body itself is
// drained (the counter rows are typed Strings + UInt64s and the floor
// transport does not materialise non-floor column types).
public struct ClickHouseProfileEvents: Sendable, Equatable {

    public let hostName: String

    public init(hostName: String) {
        self.hostName = hostName
    }
}
