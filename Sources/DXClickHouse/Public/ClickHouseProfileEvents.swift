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
