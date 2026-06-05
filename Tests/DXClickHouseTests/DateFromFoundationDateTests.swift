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

// Inserting a calendar date from a Swift Date used to mean hand-computing
// days-since-epoch. ClickHouseDate(_:) and ClickHouseDate32(_:) take a Date
// and store the floor of its day count (the time of day is dropped, since a
// Date column is day-resolution), with Date bounded to its UInt16 range
// (1970-2149) and Date32 to the wider signed range (including pre-epoch).
@Suite("ClickHouseDate / ClickHouseDate32 build from a Foundation Date")
struct DateFromFoundationDateTests {

    private static let secondsPerDay = 86_400.0

    @Test("a midnight date maps to its exact day count")
    func midnight() throws {
        let date = Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay)
        #expect(try ClickHouseDate(date).days == 20_000)
        #expect(try ClickHouseDate32(date).days == 20_000)
    }

    @Test("a mid-day date floors to the containing day")
    func midDayFloors() throws {
        let date = Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay + 50_000)
        #expect(try ClickHouseDate(date).days == 20_000)
    }

    @Test("Date32 represents pre-epoch days as negative")
    func date32PreEpoch() throws {
        let date = Date(timeIntervalSince1970: -100 * Self.secondsPerDay)
        #expect(try ClickHouseDate32(date).days == -100)
    }

    @Test("a date before 1970 is out of Date's UInt16 range")
    func dateBeforeEpochRejected() {
        let date = Date(timeIntervalSince1970: -Self.secondsPerDay)
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseDate(date) }
    }

    @Test("a date past 2149 is out of Date's UInt16 range")
    func datePast2149Rejected() {
        let date = Date(timeIntervalSince1970: 100_000 * Self.secondsPerDay)
        #expect(throws: ClickHouseError.self) { _ = try ClickHouseDate(date) }
    }
}
