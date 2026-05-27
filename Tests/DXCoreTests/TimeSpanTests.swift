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

import Testing
@testable import DXCore

@Suite
struct TimeSpanTests {

    @Test
    func timeSpan_nanosecondsFactoryStoresVerbatim() {
        #expect(TimeSpan.nanoseconds(42).nanoseconds == 42)
    }

    @Test
    func timeSpan_microsecondsFactoryConvertsToNanos() {
        #expect(TimeSpan.microseconds(1).nanoseconds == 1_000)
    }

    @Test
    func timeSpan_millisecondsFactoryConvertsToNanos() {
        #expect(TimeSpan.milliseconds(1).nanoseconds == 1_000_000)
    }

    @Test
    func timeSpan_secondsFactoryConvertsToNanos() {
        #expect(TimeSpan.seconds(1).nanoseconds == 1_000_000_000)
    }

    @Test
    func timeSpan_minutesFactoryConvertsToNanos() {
        #expect(TimeSpan.minutes(1).nanoseconds == 60_000_000_000)
    }

    @Test
    func timeSpan_hoursFactoryConvertsToNanos() {
        #expect(TimeSpan.hours(1).nanoseconds == 3_600_000_000_000)
    }

    @Test
    func timeSpan_microsecondsAccessorRoundTrips() {
        #expect(TimeSpan.milliseconds(5).microseconds == 5_000)
    }

    @Test
    func timeSpan_millisecondsAccessorRoundTrips() {
        #expect(TimeSpan.seconds(5).milliseconds == 5_000)
    }

    @Test
    func timeSpan_secondsAccessorRoundTrips() {
        #expect(TimeSpan.minutes(5).seconds == 300)
    }

    @Test
    func timeSpan_minutesAccessorRoundTrips() {
        #expect(TimeSpan.hours(2).minutes == 120)
    }

    @Test
    func timeSpan_hoursAccessorRoundTrips() {
        #expect(TimeSpan.hours(3).hours == 3)
    }

    @Test
    func timeSpan_fractionalSecondsReadsSubSecondPrecision() {
        #expect(TimeSpan.milliseconds(500).fractionalSeconds == 0.5)
    }

    @Test
    func timeSpan_comparableOrdersByNanos() {
        #expect(TimeSpan.seconds(1) < TimeSpan.seconds(2))
        #expect(TimeSpan.milliseconds(999) < TimeSpan.seconds(1))
        #expect(TimeSpan.seconds(1) == TimeSpan.milliseconds(1000))
    }

    @Test
    func timeSpan_hashableEqualWhenNanosEqual() {
        let a = TimeSpan.seconds(1)
        let b = TimeSpan.milliseconds(1000)
        var set = Set<TimeSpan>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}
