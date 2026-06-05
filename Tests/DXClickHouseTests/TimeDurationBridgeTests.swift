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

import DXClickHouse
import Testing

// A ClickHouse Time column is a signed number of seconds; Swift's Duration
// is the idiomatic value for that. ClickHouseTime exposed only its raw Int32
// seconds, so bridging to/from Duration meant doing it by hand. `duration`
// and `init(_:)` close that, second-resolution (the Time column carries no
// sub-second), with the value bounded to the Int32 seconds range.
@Suite("ClickHouseTime bridges to and from a Swift Duration")
struct TimeDurationBridgeTests {

    @Test("seconds map to a Duration and back")
    func roundTrip() throws {
        #expect(ClickHouseTime(seconds: 3_661).duration == .seconds(3_661))
        #expect(try ClickHouseTime(.seconds(3_661)).seconds == 3_661)
        #expect(ClickHouseTime(seconds: -100).duration == .seconds(-100))
        #expect(try ClickHouseTime(.seconds(-100)).seconds == -100)
    }

    @Test("a sub-second Duration is truncated to whole seconds")
    func subSecondTruncates() throws {
        #expect(try ClickHouseTime(.milliseconds(1_500)).seconds == 1)
    }

    @Test("a Duration beyond the Int32 seconds range is rejected")
    func outOfRangeRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseTime(.seconds(Int64(Int32.max) + 1))
        }
    }
}
