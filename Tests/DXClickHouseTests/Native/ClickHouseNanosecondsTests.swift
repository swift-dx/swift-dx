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
import Foundation
import Testing

@Suite("ClickHouseNanoseconds — exact-precision Int64 timestamp")
struct ClickHouseNanosecondsTests {

    @Test("init from raw Int64 preserves the value exactly")
    func initFromRawValuePreservesValue() {
        let nanos = ClickHouseNanoseconds(1_704_067_200_123_456_789)
        #expect(nanos.rawValue == 1_704_067_200_123_456_789)
    }

    @Test("Int64 round-trips through .rawValue without modification")
    func int64RoundTripsExactly() {
        let original: Int64 = 1_700_000_000_500_000_001
        let nanos = ClickHouseNanoseconds(original)
        #expect(nanos.rawValue == original, "no precision loss when constructed from Int64")
    }

    @Test("negative raw values represent pre-epoch instants")
    func negativeValuesRepresentPreEpoch() {
        let nanos = ClickHouseNanoseconds(-1_000_000_000)  // 1 second before epoch
        #expect(nanos.rawValue == -1_000_000_000)
        #expect(nanos.date.timeIntervalSince1970 == -1.0)
    }

    @Test("init(date:) and .date together round-trip lossy at the Double-precision floor (~microsecond)")
    func dateRoundTripIsApproximate() {
        // A Date that exactly represents a microsecond-precision instant
        let original = Date(timeIntervalSince1970: 1_700_000_000.000_001)
        let nanos = ClickHouseNanoseconds(date: original)
        let restored = nanos.date
        // Round-trip should be exact at microsecond precision
        let delta = abs(restored.timeIntervalSince1970 - original.timeIntervalSince1970)
        #expect(delta < 1e-6, "microsecond precision survives the round-trip")
    }

    @Test("ClickHouseNanoseconds is Equatable and Hashable")
    func equatableAndHashable() {
        let a = ClickHouseNanoseconds(42)
        let b = ClickHouseNanoseconds(42)
        let c = ClickHouseNanoseconds(43)
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("static now returns a non-trivially-recent instant")
    func nowReturnsCurrentInstant() {
        let before = Int64(Date().timeIntervalSince1970) * 1_000_000_000
        let now = ClickHouseNanoseconds.now
        let after = (Int64(Date().timeIntervalSince1970) + 1) * 1_000_000_000
        #expect(now.rawValue >= before)
        #expect(now.rawValue <= after)
    }

    // MARK: - Parameter integration

    @Test("dateTime64Nanoseconds parameter formats as single-quoted YYYY-MM-DD HH:MM:SS.NNNNNNNNN at precision 9")
    func dateTime64NanosecondsFormat() {
        let nanos = ClickHouseNanoseconds(1_704_067_200_000_000_001)  // 2024-01-01 + 1ns
        let parameter = ClickHouseQueryParameter.dateTime64Nanoseconds(nanos, name: "ts")
        #expect(parameter.value == "'2024-01-01 00:00:00.000000001'")
        #expect(parameter.name == "ts")
    }

    @Test("dateTime64Nanoseconds parameter is exactly the same as dateTime64Ticks at precision 9")
    func dateTime64NanosecondsEqualsTicksAtPrecision9() {
        let raw: Int64 = 1_700_000_000_123_456_789
        let viaNanos = ClickHouseQueryParameter.dateTime64Nanoseconds(ClickHouseNanoseconds(raw), name: "ts")
        let viaTicks = ClickHouseQueryParameter.dateTime64Ticks(raw, name: "ts", precision: 9)
        #expect(viaNanos == viaTicks)
    }

    @Test("dateTime64Nanoseconds is exact where the Date-based path is lossy")
    func dateTime64NanosecondsBeatsDatePath() {
        let raw: Int64 = 1_704_067_200_000_000_001  // 1 nanosecond past 2024-01-01
        let viaNanos = ClickHouseQueryParameter.dateTime64Nanoseconds(ClickHouseNanoseconds(raw), name: "ts")
        let lossyDate = ClickHouseNanoseconds(raw).date  // round-trip through Double
        let viaDate = ClickHouseQueryParameter.dateTime64(lossyDate, name: "ts", precision: 9)

        #expect(viaNanos.value == "'2024-01-01 00:00:00.000000001'", "exact via the integer path")
        #expect(viaNanos.value != viaDate.value, "Date path loses the trailing 1ns; this proves the gap")
    }

    @Test("a SELECT-side raw Int64 from a DateTime64(9) column round-trips losslessly back as a parameter")
    func selectThenInsertRoundTrip() {
        // Simulating: query DateTime64(9), get back .nullableDateTime64([raw], precision: 9),
        // then insert the same value via a parameter. Must produce the exact same string.
        let serverReturnedTicks: Int64 = 1_700_000_000_999_999_999
        let nanos = ClickHouseNanoseconds(serverReturnedTicks)
        let parameter = ClickHouseQueryParameter.dateTime64Nanoseconds(nanos, name: "ts")
        // Parameter value is `'YYYY-MM-DD HH:MM:SS.fffffffff'` (Field-literal
        // form); strip the surrounding quotes before splitting on `.`.
        let inner = String(parameter.value.dropFirst().dropLast())
        let parts = inner.split(separator: ".")
        #expect(parts.count == 2)
        #expect(parts[1] == "999999999", "all 9 digits preserved")
    }

}
