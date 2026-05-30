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
// sends Progress packets repeatedly (typically every ~250ms for
// non-trivial queries) — each packet reports the INCREMENTAL rows and
// bytes processed since the last update, plus the running estimate of
// `totalRows` (may grow as the server discovers more parts to scan).
//
// `writtenRows` and `writtenBytes` carry write counters for INSERT
// queries on revision >= 54_420 servers. They are `.notReported` for
// older servers or for SELECT-only flows; consumers must switch on
// the enum cases to distinguish "0 written" from "no information".
//
// Production observability pattern: accumulate `rows` across callback
// firings to track total processed; compare to `totalRows` for an
// estimated completion fraction.
public struct ClickHouseProgress: Sendable, Equatable {

    public let rows: UInt64
    public let bytes: UInt64
    public let totalRows: UInt64
    public let writtenRows: ClickHouseWriteCounter
    public let writtenBytes: ClickHouseWriteCounter

    public init(
        rows: UInt64,
        bytes: UInt64,
        totalRows: UInt64,
        writtenRows: ClickHouseWriteCounter = .notReported,
        writtenBytes: ClickHouseWriteCounter = .notReported
    ) {
        self.rows = rows
        self.bytes = bytes
        self.totalRows = totalRows
        self.writtenRows = writtenRows
        self.writtenBytes = writtenBytes
    }

}
