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

// ClickHouse stores DateTime / DateTime64 as a UTC instant; the column's
// timezone is display metadata only. Decoding to a Swift Date must therefore
// yield the same absolute instant regardless of the column timezone, and the
// DateTime64 sub-second precision must scale by the declared precision. A wrong
// timezone offset or precision divisor silently corrupts timestamps.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct DateTimeZoneProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct DateRow: Decodable, Sendable, Equatable { let v: Date }

    @Test("DateTime decodes to the same UTC instant regardless of column timezone", .timeLimit(.minutes(1)))
    func dateTimeTimezoneInvariant() async throws {
        let client = try await Self.makeClient()
        // Both select the same absolute instant (epoch 1_700_000_000) but declare
        // different display timezones; the decoded Date must be identical.
        let utc = try await client.selectAll("SELECT toDateTime(1700000000, 'UTC') AS v", as: DateRow.self)
        let ny = try await client.selectAll("SELECT toDateTime(1700000000, 'America/New_York') AS v", as: DateRow.self)
        let tokyo = try await client.selectAll("SELECT toDateTime(1700000000, 'Asia/Tokyo') AS v", as: DateRow.self)
        #expect(utc == [DateRow(v: Date(timeIntervalSince1970: 1_700_000_000))])
        #expect(ny == utc)
        #expect(tokyo == utc)
        await client.close()
    }

    @Test("DateTime64(3) decodes milliseconds to the exact instant", .timeLimit(.minutes(1)))
    func dateTime64Milliseconds() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT toDateTime64(1700000000.123, 3, 'UTC') AS v", as: DateRow.self)
        #expect(rows == [DateRow(v: Date(timeIntervalSince1970: 1_700_000_000.123))])
        await client.close()
    }

    @Test("DateTime64(6) decodes microseconds to the exact instant", .timeLimit(.minutes(1)))
    func dateTime64Microseconds() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT toDateTime64(1700000000.123456, 6, 'UTC') AS v", as: DateRow.self)
        #expect(rows.count == 1)
        let delta = abs(rows[0].v.timeIntervalSince1970 - 1_700_000_000.123456)
        #expect(delta < 0.0000005)
        await client.close()
    }

    @Test("DateTime64(3) with a non-UTC timezone keeps the same UTC instant", .timeLimit(.minutes(1)))
    func dateTime64TimezoneInvariant() async throws {
        let client = try await Self.makeClient()
        let utc = try await client.selectAll("SELECT toDateTime64(1700000000.5, 3, 'UTC') AS v", as: DateRow.self)
        let berlin = try await client.selectAll("SELECT toDateTime64(1700000000.5, 3, 'Europe/Berlin') AS v", as: DateRow.self)
        #expect(utc == [DateRow(v: Date(timeIntervalSince1970: 1_700_000_000.5))])
        #expect(berlin == utc)
        await client.close()
    }
}
