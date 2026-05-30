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
// Cumulative writtenRows is taken from the last Progress packet emitted
// before EndOfStream.
public struct RawClickHouseInsertSummary: Sendable, Equatable {

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
}
