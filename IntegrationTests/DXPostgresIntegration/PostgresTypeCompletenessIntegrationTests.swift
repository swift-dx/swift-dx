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

// Documents the type guarantees against a live server (PostgreSQL or YugabyteDB):
// any column type is retrievable as its text rendering, and the richly-typed
// decoders handle their value boundaries.
@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresTypeCompletenessIntegrationTests {

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text) ?? Decimal.zero
    }

    // The simple query protocol returns every value as text, so a type without a
    // dedicated decoder is still readable as its text rendering via String.
    @Test func anyTypeIsRetrievableAsTextViaSimpleQuery() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("""
                SELECT '13:14:15'::time AS clock,
                       '1 day 02:03:04'::interval AS span,
                       1234.56::money AS amount,
                       '192.168.0.1/24'::inet AS address,
                       '08:00:2b:01:02:03'::macaddr AS hardware,
                       '(1,2)'::point AS location,
                       B'1010'::bit(4) AS flags,
                       '[1,10)'::int4range AS span_range,
                       'NaN'::numeric AS not_a_number
                """).rows[0]
            #expect(try row.decode(String.self, named: "clock") == "13:14:15")
            #expect(try row.decode(String.self, named: "span") == "1 day 02:03:04")
            #expect(try row.decode(String.self, named: "address") == "192.168.0.1/24")
            #expect(try row.decode(String.self, named: "hardware") == "08:00:2b:01:02:03")
            #expect(try row.decode(String.self, named: "location") == "(1,2)")
            #expect(try row.decode(String.self, named: "flags") == "1010")
            #expect(try row.decode(String.self, named: "span_range") == "[1,10)")
            #expect(try row.decode(String.self, named: "not_a_number") == "NaN")
        }
    }

    // On the parameterized (binary) path, a type without a binary decoder is read
    // by casting it to text in the SQL.
    @Test func exoticTypeIsRetrievableViaTextCastOnParameterizedQuery() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT $1::int AS marker, ('1 day 02:03:04'::interval)::text AS span", binding: [1]).rows[0]
            #expect(try row.decode(Int.self, named: "marker") == 1)
            #expect(try row.decode(String.self, named: "span") == "1 day 02:03:04")
        }
    }

    @Test func integerWidthBoundariesRoundTrip() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query(
                "SELECT $1::int2 AS a, $2::int2 AS b, $3::int4 AS c, $4::int4 AS d, $5::int8 AS e, $6::int8 AS f",
                binding: [Int16.min, Int16.max, Int32.min, Int32.max, Int64.min, Int64.max]
            ).rows[0]
            #expect(try row.decode(Int16.self, named: "a") == Int16.min)
            #expect(try row.decode(Int16.self, named: "b") == Int16.max)
            #expect(try row.decode(Int32.self, named: "c") == Int32.min)
            #expect(try row.decode(Int32.self, named: "d") == Int32.max)
            #expect(try row.decode(Int64.self, named: "e") == Int64.min)
            #expect(try row.decode(Int64.self, named: "f") == Int64.max)
        }
    }

    @Test func numericExtremesRoundTrip() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            for literal in ["0", "-0.000000001", "123456789012345678901234567890.123456789", "-99999999999999999999"] {
                let row = try await postgres.query("SELECT $1::numeric AS n", binding: [decimal(literal)]).rows[0]
                #expect(try row.decode(Decimal.self, named: "n") == decimal(literal))
            }
        }
    }

    @Test func textEdgeCasesRoundTrip() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            for value in ["", "ünïcödé — 日本語 — 😀", "tab\tand\nnewline", String(repeating: "x", count: 100_000)] {
                let row = try await postgres.query("SELECT $1::text AS s", binding: [value]).rows[0]
                #expect(try row.decode(String.self, named: "s") == value)
            }
        }
    }

    @Test func largeByteaRoundTrips() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let payload = (0..<8192).map { UInt8($0 % 256) }
            let row = try await postgres.query("SELECT $1::bytea AS b", binding: [payload]).rows[0]
            #expect(try row.decode([UInt8].self, named: "b") == payload)
        }
    }

    @Test func sqlNullDecodesAcrossTypes() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT NULL::int4 AS i, NULL::text AS t, NULL::numeric AS n, NULL::uuid AS u, $1::int AS marker", binding: [1]).rows[0]
            #expect(try row.decodeNullable(Int.self, named: "i") == .sqlNull)
            #expect(try row.decodeNullable(String.self, named: "t") == .sqlNull)
            #expect(try row.decodeNullable(Decimal.self, named: "n") == .sqlNull)
            #expect(try row.decodeNullable(UUID.self, named: "u") == .sqlNull)
        }
    }
}
