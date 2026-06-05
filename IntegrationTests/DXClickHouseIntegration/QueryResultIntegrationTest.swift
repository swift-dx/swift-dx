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

// The thin query API runs any SQL and returns its columns directly, with no
// Codable type. Verified against a real server, including a result that spans
// multiple blocks and a query with mixed column types.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct QueryResultIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    @Test("query returns columns read by name with no Codable type", .timeLimit(.minutes(1)))
    func readsColumnsByName() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT toUInt64(42) AS id, 'hello' AS name, 1.5 AS value")
        #expect(result.rowCount == 1)
        #expect(result.columnNames == ["id", "name", "value"])
        #expect(try result.uint64("id", 0) == 42)
        #expect(try result.string("name", 0) == "hello")
        #expect(try result.double("value", 0) == 1.5)
        await client.close()
    }

    @Test("query reads Nullable columns and small integer widths", .timeLimit(.minutes(1)))
    func nullableAndSmallInts() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("""
            SELECT CAST(NULL AS Nullable(UInt64)) AS a,
                   CAST(7 AS Nullable(UInt64)) AS b,
                   toUInt8(5) AS c,
                   toInt16(-300) AS d,
                   CAST(NULL AS Nullable(String)) AS e
            """)
        #expect(result.rowCount == 1)
        #expect(try result.isNull("a", 0) == true)
        #expect(try result.isNull("b", 0) == false)
        #expect(try result.uint64("b", 0) == 7)
        #expect(try result.uint8("c", 0) == 5)
        #expect(try result.int16("d", 0) == -300)
        #expect(try result.isNull("e", 0) == true)
        await client.close()
    }

    @Test("query reads DateTime, Date, UUID, and Decimal columns", .timeLimit(.minutes(1)))
    func readsWiderTypes() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("""
            SELECT toDateTime('2026-06-02 12:00:00', 'UTC') AS dt,
                   toUnixTimestamp(toDateTime('2026-06-02 12:00:00', 'UTC')) AS dt_unix,
                   toDateTime64('2026-06-02 12:00:00.500', 3, 'UTC') AS dt64,
                   toUUID('00112233-4455-6677-8899-aabbccddeeff') AS u,
                   toString(toUUID('00112233-4455-6677-8899-aabbccddeeff')) AS u_str,
                   toDecimal64(123.45, 2) AS dec,
                   toString(toDecimal64(123.45, 2)) AS dec_str
            """)
        #expect(result.rowCount == 1)
        // The DateTime decodes to the same instant the server's unix timestamp denotes.
        #expect(try result.date("dt", 0).timeIntervalSince1970 == Double(try result.uint32("dt_unix", 0)))
        // DateTime64(3) carries the half-second.
        #expect(try result.date("dt64", 0).timeIntervalSince1970 == Double(try result.uint32("dt_unix", 0)) + 0.5)
        // UUID matches the server's own rendering.
        #expect(try result.uuid("u", 0) == UUID(uuidString: try result.string("u_str", 0)))
        // Decimal renders identically to the server.
        #expect(try result.decimal("dec", 0).description == (try result.string("dec_str", 0)))
        await client.close()
    }

    @Test("query reads LowCardinality(String) and Enum columns as strings", .timeLimit(.minutes(1)))
    func readsLowCardinalityAndEnum() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("""
            SELECT CAST('active' AS LowCardinality(String)) AS status,
                   CAST('beta' AS Enum8('alpha' = 1, 'beta' = 2)) AS phase
            """)
        #expect(result.rowCount == 1)
        #expect(try result.string("status", 0) == "active")
        #expect(try result.string("phase", 0) == "beta")
        await client.close()
    }

    @Test("query reads Array(String/Int64/UInt64/Float64) columns", .timeLimit(.minutes(1)))
    func readsArrays() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("""
            SELECT ['a', 'b', 'c'] AS tags,
                   [toInt64(-1), toInt64(2)] AS ints,
                   [toUInt64(10), toUInt64(20)] AS uints,
                   [toFloat64(1.5), toFloat64(2.5)] AS dbls
            """)
        #expect(result.rowCount == 1)
        #expect(try result.stringArray("tags", 0) == ["a", "b", "c"])
        #expect(try result.int64Array("ints", 0) == [-1, 2])
        #expect(try result.uint64Array("uints", 0) == [10, 20])
        #expect(try result.doubleArray("dbls", 0) == [1.5, 2.5])
        await client.close()
    }

    @Test("query reads Nullable(Decimal) and Nullable(DateTime64) via the generic nullable wrapper", .timeLimit(.minutes(1)))
    func nullableWiderTypes() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("""
            SELECT CAST(toDecimal64(123.45, 2) AS Nullable(Decimal(9, 2))) AS dec,
                   CAST(NULL AS Nullable(Decimal(9, 2))) AS dec_null,
                   CAST(toDateTime64('2026-06-02 12:00:00.500', 3, 'UTC') AS Nullable(DateTime64(3, 'UTC'))) AS ts,
                   toUnixTimestamp(toDateTime('2026-06-02 12:00:00', 'UTC')) AS ts_unix
            """)
        #expect(result.rowCount == 1)
        #expect(try result.isNull("dec", 0) == false)
        #expect(try result.isNull("dec_null", 0) == true)
        #expect(try result.decimal("dec", 0).description == "123.45")
        #expect(try result.date("ts", 0).timeIntervalSince1970 == Double(try result.uint32("ts_unix", 0)) + 0.5)
        await client.close()
    }

    @Test("query spans multiple result blocks", .timeLimit(.minutes(1)))
    func spansBlocks() async throws {
        let client = try await Self.makeClient()
        let result = try await client.query("SELECT number AS id, toString(number % 10) AS name FROM numbers(200000) ORDER BY number")
        #expect(result.rowCount == 200000)
        #expect(try result.uint64("id", 0) == 0)
        #expect(try result.uint64("id", 199999) == 199999)
        #expect(try result.string("name", 123456) == "6")
        var checksum: UInt64 = 0
        for row in 0..<result.rowCount { checksum &+= try result.uint64("id", row) }
        #expect(checksum == (199999 * 200000) / 2)
        await client.close()
    }
}
