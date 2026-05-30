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

// Per-query write counter reported in `ClickHouseProgress`. The two
// values are populated for INSERT queries by servers at revision
// 54_420 or higher. `notReported` means either this is a SELECT-only
// query or the negotiated server revision predates the field's
// introduction — the consumer cannot tell from a value alone, but
// either way the underlying semantic is "no rows/bytes were written
// to a destination table on the path that yielded this snapshot."
public enum ClickHouseWriteCounter: Sendable, Equatable {

    case notReported
    case rows(UInt64)

    public var value: UInt64 {
        switch self {
        case .notReported: 0
        case .rows(let count): count
        }
    }

}
