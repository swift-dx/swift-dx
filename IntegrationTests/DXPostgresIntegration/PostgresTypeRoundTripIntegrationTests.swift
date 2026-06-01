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

// These exercise binary-format decoding: parameterized queries request binary
// results, so each decode here runs through PostgresBinaryDecoding. A parallel
// simple-query check covers the text path for the same types.
@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresTypeRoundTripIntegrationTests {

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text) ?? Decimal.zero
    }

    @Test func binaryIntegersFloatsAndBool() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query(
                "SELECT $1::int2 AS a, $2::int4 AS b, $3::int8 AS c, $4::float4 AS d, $5::float8 AS e, $6::bool AS f",
                binding: [Int16(7), Int32(70000), Int64(9_000_000_000), Float(1.5), Double(2.25), true]
            ).rows[0]
            #expect(try row.decode(Int16.self, named: "a") == 7)
            #expect(try row.decode(Int32.self, named: "b") == 70000)
            #expect(try row.decode(Int64.self, named: "c") == 9_000_000_000)
            #expect(try row.decode(Float.self, named: "d") == 1.5)
            #expect(try row.decode(Double.self, named: "e") == 2.25)
            #expect(try row.decode(Bool.self, named: "f") == true)
        }
    }

    @Test func binaryUUIDByteaAndNumeric() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let uuid = UUID()
            let payload: [UInt8] = [0x00, 0xde, 0xad, 0xbe, 0xef, 0xff]
            let row = try await postgres.query(
                "SELECT $1::uuid AS u, $2::bytea AS b, $3::numeric AS n",
                binding: [uuid, payload, decimal("-12345.6789")]
            ).rows[0]
            #expect(try row.decode(UUID.self, named: "u") == uuid)
            #expect(try row.decode([UInt8].self, named: "b") == payload)
            #expect(try row.decode(Decimal.self, named: "n") == decimal("-12345.6789"))
        }
    }

    @Test func binaryTimestampsRoundTrip() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let instant = Date(timeIntervalSince1970: 1_780_000_000.123456)
            let row = try await postgres.query(
                "SELECT $1::timestamptz AS tstz, $1::timestamp AS ts, '2026-05-31'::date AS d",
                binding: [instant]
            ).rows[0]
            let decodedTstz = try row.decode(Date.self, named: "tstz")
            #expect(abs(decodedTstz.timeIntervalSince(instant)) < 0.001)
            let decodedDate = try row.decode(Date.self, named: "d")
            #expect(abs(decodedDate.timeIntervalSince1970 - 1_780_185_600) < 1)
        }
    }

    @Test func binaryNumericExtremes() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            for literal in ["0", "1", "100000000", "0.00000001", "-999999999999.999999"] {
                let row = try await postgres.query("SELECT $1::numeric AS n", binding: [decimal(literal)]).rows[0]
                #expect(try row.decode(Decimal.self, named: "n") == decimal(literal))
            }
        }
    }

    @Test func jsonbCodableRoundTrip() async throws {
        struct Document: Codable, Equatable, Sendable {
            let id: Int
            let tags: [String]
            let active: Bool
        }
        let document = Document(id: 7, tags: ["alpha", "beta"], active: true)
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT $1::jsonb AS body, $2::json AS plain", binding: [PostgresJSON(document), PostgresJSON(document)]).rows[0]
            #expect(try row.decodeJSON(Document.self, named: "body") == document)
            #expect(try row.decodeJSON(Document.self, named: "plain") == document)
        }
    }

    @Test func textPathDecodesSameTypes() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT 42::int4 AS a, 3.5::float8 AS b, true AS c, '2026-05-31 06:40:30+00'::timestamptz AS t, 9.99::numeric AS n").rows[0]
            #expect(try row.decode(Int.self, named: "a") == 42)
            #expect(try row.decode(Double.self, named: "b") == 3.5)
            #expect(try row.decode(Bool.self, named: "c") == true)
            #expect(try row.decode(Decimal.self, named: "n") == Decimal(string: "9.99"))
            let timestamp = try row.decode(Date.self, named: "t")
            #expect(timestamp.timeIntervalSince1970 > 0)
        }
    }
}
