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

@testable import DXClickHouse
import Testing

// The reconnect loop applies equal jitter to every backoff sleep so a
// fleet of connections that all dropped at the same instant spread their
// retries instead of stampeding the broker in lockstep on identical
// 100ms/200ms/400ms boundaries the moment it recovers. The jitter is a
// pure function of (backoff, fraction) so it can be asserted exactly
// here; the live loop supplies a random fraction in [0, 1).
@Suite("Reconnect backoff is jittered to avoid synchronized retry storms")
struct ReconnectJitterTests {

    private func nanoseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
    }

    @Test("fraction 0 yields exactly half the nominal backoff (the floor)")
    func floorIsHalf() {
        let jittered = ClickHouseConnection.jitteredBackoff(.milliseconds(100), fraction: 0.0)
        #expect(nanoseconds(jittered) == 50_000_000)
    }

    @Test("a mid fraction lands in the upper half of the window")
    func midFraction() {
        let jittered = ClickHouseConnection.jitteredBackoff(.milliseconds(100), fraction: 0.5)
        #expect(nanoseconds(jittered) == 75_000_000)
    }

    @Test("every output stays within [half, full) of the nominal backoff")
    func boundedWindow() {
        let nominal = nanoseconds(.milliseconds(200))
        for fraction in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 0.999] {
            let value = nanoseconds(ClickHouseConnection.jitteredBackoff(.milliseconds(200), fraction: fraction))
            #expect(value >= nominal / 2)
            #expect(value < nominal)
        }
    }

    // The core anti-stampede property: two connections sharing the same
    // nominal backoff but drawing different random fractions sleep for
    // different durations, so they do not retry at the same instant. A
    // no-jitter implementation would return the same value for both and
    // fail this.
    @Test("different fractions produce different sleeps, so retries decorrelate")
    func differentFractionsDecorrelate() {
        let low = ClickHouseConnection.jitteredBackoff(.milliseconds(100), fraction: 0.1)
        let high = ClickHouseConnection.jitteredBackoff(.milliseconds(100), fraction: 0.9)
        #expect(nanoseconds(low) < nanoseconds(high))
    }

    @Test("a zero backoff (fail-fast) is returned unchanged, never negative")
    func zeroBackoffUnchanged() {
        let jittered = ClickHouseConnection.jitteredBackoff(.zero, fraction: 0.7)
        #expect(nanoseconds(jittered) == 0)
    }

    @Test("an out-of-range fraction is clamped into the window")
    func fractionClamped() {
        let nominal = nanoseconds(.milliseconds(100))
        let below = nanoseconds(ClickHouseConnection.jitteredBackoff(.milliseconds(100), fraction: -5.0))
        let above = nanoseconds(ClickHouseConnection.jitteredBackoff(.milliseconds(100), fraction: 5.0))
        #expect(below == nominal / 2)
        #expect(above >= nominal / 2)
        #expect(above < nominal)
    }
}
