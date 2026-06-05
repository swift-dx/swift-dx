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
import Foundation
import Testing

// Symmetric with ClickHouseDate(_:) / ClickHouseDate32(_:): a decoded
// ClickHouseDate value exposes only its day count, so reading it as a
// Foundation Date meant multiplying by seconds-per-day by hand. A `date`
// accessor (like ClickHouseDateTime64.date) yields the midnight-UTC instant
// of the day and round-trips with the Date initializer.
@Suite("ClickHouseDate / ClickHouseDate32 expose a Foundation Date")
struct DateToFoundationDateTests {

    private static let secondsPerDay = 86_400.0

    @Test("the day count maps to the midnight-UTC instant")
    func midnightInstant() {
        #expect(ClickHouseDate(days: 20_000).date == Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay))
        #expect(ClickHouseDate32(days: -100).date == Date(timeIntervalSince1970: -100 * Self.secondsPerDay))
    }

    @Test("the Date initializer and the date accessor round-trip at day resolution")
    func roundTrip() throws {
        let instant = Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay + 50_000)
        #expect(try ClickHouseDate(instant).date == Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay))
        #expect(try ClickHouseDate32(instant).date == Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay))
    }
}
