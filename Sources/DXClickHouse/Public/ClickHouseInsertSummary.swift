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

// Returned to callers of the typed INSERT path so they can observe the
// exact number of rows the server reported back via its Progress
// packets, plus the number of blocks the client serialised and sent.
// writtenRows and writtenBytes are the sum of the per-packet increments
// the server reported across every Progress packet up to EndOfStream.
public struct ClickHouseInsertSummary: Sendable, Equatable {

    public let rowsSent: Int
    public let blocksSent: Int
    public let writtenRows: UInt64
    public let writtenBytes: UInt64

    public init(rowsSent: Int, blocksSent: Int, writtenRows: UInt64, writtenBytes: UInt64) {
        self.rowsSent = rowsSent
        self.blocksSent = blocksSent
        self.writtenRows = writtenRows
        self.writtenBytes = writtenBytes
    }

    // Combines this summary with another, used when a streamed INSERT is
    // sent as several batched INSERTs and their counts must be totalled.
    package func adding(_ other: ClickHouseInsertSummary) -> ClickHouseInsertSummary {
        ClickHouseInsertSummary(
            rowsSent: rowsSent + other.rowsSent,
            blocksSent: blocksSent + other.blocksSent,
            writtenRows: writtenRows + other.writtenRows,
            writtenBytes: writtenBytes + other.writtenBytes
        )
    }
}
