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

    // Builds the seconds count from a Swift Duration. The Time column is
    // second-resolution, so any sub-second part of the Duration is dropped.
    // Throws for durations whose whole-second magnitude exceeds the Int32
    // range a Time column can hold.
    public init(_ duration: Duration) throws(ClickHouseError) {
        let seconds = duration.components.seconds
        guard (Int64(Int32.min)...Int64(Int32.max)).contains(seconds) else {
            throw .protocolError(stage: "time", message: "duration \(duration) is outside the Time range (\(Int32.min)...\(Int32.max) seconds)")
        }
        self.seconds = Int32(seconds)
    }

    // The signed elapsed time this value represents, as a Swift Duration.
    public var duration: Duration {
        .seconds(Int64(seconds))
    }
}
