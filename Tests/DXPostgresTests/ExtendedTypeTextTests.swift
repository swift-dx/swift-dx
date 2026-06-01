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

import Foundation
import Testing

@testable import DXPostgres

@Suite struct ExtendedTypeTextTests {

    @Test func parsesTimeWithFractionAndZone() throws {
        #expect(try PostgresTimeText.parse("13:14:15").microsecondsSinceMidnight == Int64((13 * 3600 + 14 * 60 + 15)) * 1_000_000)
        #expect(try PostgresTimeText.parse("13:14:15.5").microsecond == 500_000)
        #expect(try PostgresTimeText.parse("01:00:00+05").zoneOffsetSeconds == 18000)
        #expect(try PostgresTimeText.parse("01:00:00-08").zoneOffsetSeconds == -28800)
    }

    @Test func timeComponentsAndDescription() {
        let time = PostgresTime(microsecondsSinceMidnight: Int64(13 * 3600 + 14 * 60 + 15) * 1_000_000 + 250_000)
        #expect(time.hour == 13)
        #expect(time.minute == 14)
        #expect(time.second == 15)
        #expect(time.microsecond == 250_000)
        #expect(time.description == "13:14:15.250000")
    }

    @Test func parsesIntervalComponents() throws {
        let full = try PostgresIntervalText.parse("1 year 2 mons 3 days 04:05:06")
        #expect(full.months == 14)
        #expect(full.days == 3)
        #expect(full.microseconds == Int64(4 * 3600 + 5 * 60 + 6) * 1_000_000)
        #expect(try PostgresIntervalText.parse("1 mon").months == 1)
        #expect(try PostgresIntervalText.parse("00:00:01.5").microseconds == 1_500_000)
        #expect(try PostgresIntervalText.parse("-00:00:01").microseconds == -1_000_000)
    }

    @Test func parsesIPv4Inet() throws {
        let withPrefix = try PostgresInetText.parse("192.168.0.1/24")
        #expect(withPrefix.address == [192, 168, 0, 1])
        #expect(withPrefix.prefixLength == 24)
        #expect(withPrefix.isIPv6 == false)
        #expect(try PostgresInetText.parse("10.0.0.5").prefixLength == 32)
        #expect(PostgresInet(isIPv6: false, address: [192, 168, 0, 1], prefixLength: 24, isCIDR: false).description == "192.168.0.1/24")
    }

    @Test func rejectsIPv6Text() {
        #expect(throws: PostgresError.self) {
            try PostgresInetText.parse("::1/128")
        }
    }

    @Test func sanitizesMoneyText() throws {
        let value = PostgresDecodingValue(bytes: Array("$1,234.56".utf8), format: .text, dataTypeObjectID: 790)
        #expect(try PostgresTextDecoding.decimal(value) == Decimal(string: "1234.56"))
        let negative = PostgresDecodingValue(bytes: Array("($5.00)".utf8), format: .text, dataTypeObjectID: 790)
        #expect(try PostgresTextDecoding.decimal(negative) == Decimal(string: "-5.00"))
    }
}
