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

// A value destined for a ClickHouse Date32 column. The wire value is the
// signed number of days since the Unix epoch (1970-01-01); negative days
// reach back before the epoch.
public struct ClickHouseDate32: Sendable, Hashable, Codable {

    public let days: Int32

    public init(days: Int32) {
        self.days = days
    }
}
