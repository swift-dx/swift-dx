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

@Suite struct PostgresTimestampTextTests {

    private func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    @Test func parsesDateOnlyAsMidnightUTC() throws {
        let date = try PostgresTimestampText.parse("2026-05-31")
        #expect(date == instant("2026-05-31T00:00:00.000Z"))
    }

    @Test func parsesTimestampWithoutZoneAsUTC() throws {
        let date = try PostgresTimestampText.parse("2026-05-31 06:40:30")
        #expect(date == instant("2026-05-31T06:40:30.000Z"))
    }

    @Test func parsesFractionalSeconds() throws {
        let date = try PostgresTimestampText.parse("2026-05-31 06:40:30.419123")
        #expect(abs(date.timeIntervalSince(instant("2026-05-31T06:40:30.419Z")) - 0.000123) < 0.0000005)
    }

    @Test func appliesPositiveZoneOffset() throws {
        let date = try PostgresTimestampText.parse("2026-05-31 06:40:30+05:30")
        #expect(date == instant("2026-05-31T01:10:30.000Z"))
    }

    @Test func appliesNegativeHourOnlyZoneOffset() throws {
        let date = try PostgresTimestampText.parse("2026-05-31 06:40:30-08")
        #expect(date == instant("2026-05-31T14:40:30.000Z"))
    }

    @Test func acceptsTrailingZulu() throws {
        let date = try PostgresTimestampText.parse("2026-05-31 06:40:30Z")
        #expect(date == instant("2026-05-31T06:40:30.000Z"))
    }

    @Test func rejectsMalformedDate() {
        #expect(throws: PostgresError.self) {
            try PostgresTimestampText.parse("not-a-timestamp")
        }
    }
}
