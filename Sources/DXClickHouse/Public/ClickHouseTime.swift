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

// A value destined for a ClickHouse Time column. The wire value is the
// signed number of seconds within a day-of-time, stored as a 4-byte
// little-endian Int32; negative values represent times before midnight.
public struct ClickHouseTime: Sendable, Hashable, Codable {

    public let seconds: Int32

    public init(seconds: Int32) {
        self.seconds = seconds
    }
}
