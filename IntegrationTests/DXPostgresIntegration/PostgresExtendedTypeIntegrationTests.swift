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

import DXPostgres
import Foundation
import Testing

// Round-trips the extended typed decoders (money, time, interval, inet) over both
// the binary path (parameterized queries) and the text path (simple queries).
@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresExtendedTypeIntegrationTests {

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text) ?? Decimal.zero
    }

    @Test func moneyRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let binary = try await postgres.query("SELECT $1::money AS m", binding: [decimal("1234.56")]).rows[0]
            #expect(try binary.decode(Decimal.self, named: "m") == decimal("1234.56"))
            let text = try await postgres.query("SELECT 9.99::money AS m").rows[0]
            #expect(try text.decode(Decimal.self, named: "m") == decimal("9.99"))
        }
    }

    @Test func timeRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresTime(microsecondsSinceMidnight: Int64(13 * 3600 + 14 * 60 + 15) * 1_000_000 + 500_000)
            let binary = try await postgres.query("SELECT $1::time AS t", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresTime.self, named: "t") == value)
            let text = try await postgres.query("SELECT '06:07:08'::time AS t").rows[0]
            #expect(try text.decode(PostgresTime.self, named: "t").hour == 6)
        }
    }

    @Test func intervalRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresInterval(months: 14, days: 3, microseconds: Int64(4 * 3600 + 5 * 60 + 6) * 1_000_000)
            let binary = try await postgres.query("SELECT $1::interval AS iv", binding: [value]).rows[0]
            #expect(try binary.decode(PostgresInterval.self, named: "iv") == value)
            let text = try await postgres.query("SELECT '2 mons 5 days 01:02:03'::interval AS iv").rows[0]
            let decoded = try text.decode(PostgresInterval.self, named: "iv")
            #expect(decoded.months == 2)
            #expect(decoded.days == 5)
        }
    }

    @Test func inetRoundTripsBinaryAndText() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let value = PostgresInet(isIPv6: false, address: [192, 168, 1, 100], prefixLength: 24, isCIDR: false)
            let binary = try await postgres.query("SELECT $1::inet AS n", binding: [value]).rows[0]
            let decoded = try binary.decode(PostgresInet.self, named: "n")
            #expect(decoded.address == [192, 168, 1, 100])
            #expect(decoded.prefixLength == 24)
            #expect(decoded.isIPv6 == false)
            let text = try await postgres.query("SELECT '10.0.0.5/16'::inet AS n").rows[0]
            #expect(try text.decode(PostgresInet.self, named: "n").address == [10, 0, 0, 5])
        }
    }

    @Test func ipv6InetRoundTripsBinary() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            // A bound parameter forces the extended protocol so the IPv6 inet
            // column comes back in binary, which is the supported IPv6 path.
            let row = try await postgres.query("SELECT '2001:db8::1'::inet AS n, $1::int AS marker", binding: [1]).rows[0]
            let decoded = try row.decode(PostgresInet.self, named: "n")
            #expect(decoded.isIPv6 == true)
            #expect(decoded.address.count == 16)
        }
    }
}
