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

// ClickHouseTime64 carries a sub-second tick count at a declared precision.
// Bridging to a Swift Duration is the natural read, but it can fail in ways
// the second-resolution Time cannot: an unrepresentable precision, or a
// Duration whose tick count overflows Int64 at the chosen precision. The
// accessor is therefore a throwing method rather than a property.
@Suite("ClickHouseTime64 bridges to and from a Swift Duration")
struct Time64DurationBridgeTests {

    @Test("microsecond ticks map to a Duration and back")
    func roundTripMicroseconds() throws {
        #expect(try ClickHouseTime64(ticks: 1_234_567, precision: 6).duration() == .microseconds(1_234_567))
        #expect(try ClickHouseTime64(.microseconds(1_234_567), precision: 6).ticks == 1_234_567)
    }

    @Test("negative ticks keep a consistent sign across the bridge")
    func roundTripNegative() throws {
        #expect(try ClickHouseTime64(ticks: -1_234, precision: 3).duration() == .milliseconds(-1_234))
        #expect(try ClickHouseTime64(.milliseconds(-1_234), precision: 3).ticks == -1_234)
    }

    @Test("precision 0 is whole-second ticks")
    func precisionZero() throws {
        #expect(try ClickHouseTime64(ticks: 3_661, precision: 0).duration() == .seconds(3_661))
        #expect(try ClickHouseTime64(.seconds(3_661), precision: 0).ticks == 3_661)
    }

    @Test("a precision beyond the representable range is rejected")
    func precisionOutOfRange() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseTime64(ticks: 0, precision: 19).duration()
        }
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseTime64(.seconds(1), precision: 19)
        }
    }

    @Test("a Duration whose ticks overflow Int64 at the precision is rejected")
    func tickOverflowRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseTime64(.seconds(10_000_000_000_000), precision: 9)
        }
    }
}
