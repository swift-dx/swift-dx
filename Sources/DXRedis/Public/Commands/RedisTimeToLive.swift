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

// The three states Redis distinguishes for a key's time to live, modeled as
// named cases rather than the sentinel integers (-2, -1, remaining) the PTTL
// command returns on the wire.
public enum RedisTimeToLive: Sendable, Hashable {

    case keyMissing
    case noExpiry
    case milliseconds(Int)

    static func decode(_ raw: Int64) -> RedisTimeToLive {
        switch raw {
        case -2: .keyMissing
        case -1: .noExpiry
        default: .milliseconds(Int(raw))
        }
    }
}
