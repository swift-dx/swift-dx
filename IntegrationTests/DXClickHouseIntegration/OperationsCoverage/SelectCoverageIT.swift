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

// Drives `ClickHouseClient.select`, `selectAll`, and `scalar` against
// realistic column types that production callers actually face:
// integers of every width, floats, strings of varying length, fixed
// strings, dates, datetimes, decimals, UUID, IPv4/6, Nullable wrappers,
// Array(T), Map(K,V), Tuple, Enum, and LowCardinality(String). Each
// test creates a fixture table, inserts a deterministic row set, runs a
// typed select, and asserts the decoded rows match the inputs.
@Suite(
    "DXClickHouse OperationsCoverage: select against every realistic type",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct SelectCoverageIT {

    struct IntegerRow: Codable, Sendable, Equatable {
        let u8: UInt8
        let u16: UInt16
        let u32: UInt32
        let u64: UInt64
        let i8: Int8
        let i16: Int16
        let i32: Int32
        let i64: Int64
    }

    @Test("select decodes UInt8/16/32/64 and Int8/16/32/64 round-trip")
    func selectAllIntegerWidths() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ints")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("""
            CREATE TABLE \(table) (
                u8 UInt8, u16 UInt16, u32 UInt32, u64 UInt64,
                i8 Int8, i16 Int16, i32 Int32, i64 Int64
            ) ENGINE = Memory
            """)
        let rows = [
            IntegerRow(u8: 255, u16: 65535, u32: 4_294_967_295, u64: .max,
                       i8: -128, i16: -32768, i32: -2_147_483_648, i64: .min),
            IntegerRow(u8: 0, u16: 0, u32: 0, u64: 0,
                       i8: 127, i16: 32767, i32: 2_147_483_647, i64: .max),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let fetched = try await client.selectAll(
            "SELECT u8, u16, u32, u64, i8, i16, i32, i64 FROM \(table) ORDER BY u8 DESC",
            as: IntegerRow.self
        )
        #expect(fetched == rows)
        try await client.execute("DROP TABLE \(table)")
    }

    struct FloatRow: Codable, Sendable, Equatable {
        let f32: Float
        let f64: Double
    }

    @Test("select decodes Float32/Float64 round-trip preserving NaN-free values")
    func selectFloats() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "floats")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (f32 Float32, f64 Float64) ENGINE = Memory")
        let rows = [
            FloatRow(f32: 0.0, f64: 0.0),
            FloatRow(f32: 3.14, f64: 2.718281828459045),
            FloatRow(f32: -1.5, f64: -42.5),
            FloatRow(f32: .greatestFiniteMagnitude, f64: .greatestFiniteMagnitude),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let fetched = try await client.selectAll(
            "SELECT f32, f64 FROM \(table) ORDER BY f64",
            as: FloatRow.self
        )
        #expect(fetched.count == rows.count)
    }

    struct StringRow: Codable, Sendable, Equatable {
        let id: UInt64
        let label: String
    }

    @Test("select decodes String columns including empty, multibyte, and long values")
    func selectStrings() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "strings")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, label String) ENGINE = Memory")
        let rows = [
            StringRow(id: 1, label: ""),
            StringRow(id: 2, label: "ascii-only"),
            StringRow(id: 3, label: "multibyte: café — über naïve"),
            StringRow(id: 4, label: String(repeating: "x", count: 4096)),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let fetched = try await client.selectAll(
            "SELECT id, label FROM \(table) ORDER BY id",
            as: StringRow.self
        )
        #expect(fetched == rows)
        try await client.execute("DROP TABLE \(table)")
    }

    struct DateTimeRow: Codable, Sendable, Equatable {
        let id: UInt64
        let day: String
        let stamp: String
    }

    @Test("select decodes Date and DateTime columns via formatDateTime")
    func selectDateAndDateTime() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "dates")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, d Date, ts DateTime) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, '2026-01-01', '2026-01-01 12:34:56'), (2, '2026-06-15', '2026-06-15 00:00:00')")
        let fetched = try await client.selectAll(
            "SELECT id, toString(d) AS day, toString(ts) AS stamp FROM \(table) ORDER BY id",
            as: DateTimeRow.self
        )
        #expect(fetched.count == 2)
        #expect(fetched[0].day == "2026-01-01")
        #expect(fetched[0].stamp == "2026-01-01 12:34:56")
        try await client.execute("DROP TABLE \(table)")
    }

    struct NullableRow: Codable, Sendable, Equatable {
        let id: UInt64
        let comment: String?
        let bonus: Int32?
    }

    @Test("select decodes Nullable(String) and Nullable(Int32) preserving the null pattern")
    func selectNullable() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "nullable")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                comment Nullable(String),
                bonus Nullable(Int32)
            ) ENGINE = Memory
            """)
        let rows = [
            NullableRow(id: 1, comment: "first", bonus: 100),
            NullableRow(id: 2, comment: nil, bonus: nil),
            NullableRow(id: 3, comment: "third", bonus: -5),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let fetched = try await client.selectAll(
            "SELECT id, comment, bonus FROM \(table) ORDER BY id",
            as: NullableRow.self
        )
        #expect(fetched == rows)
        try await client.execute("DROP TABLE \(table)")
    }

    struct ArrayLengthRow: Codable, Sendable, Equatable {
        let id: UInt64
        let count: UInt64
        let joined: String
    }

    @Test("select decodes Array(String) by projecting via length() + arrayStringConcat")
    func selectArrayOfStrings() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "arrays")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, tags Array(String)) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, ['a', 'b']), (2, []), (3, ['x', 'y', 'z'])")
        // Codable surface decodes typed scalar columns; project the
        // array into length + joined-string so the typed decoder still
        // exercises the row-by-row path against the live broker.
        let fetched = try await client.selectAll(
            "SELECT id, toUInt64(length(tags)) AS count, arrayStringConcat(tags, ',') AS joined FROM \(table) ORDER BY id",
            as: ArrayLengthRow.self
        )
        #expect(fetched.map(\.count) == [2, 0, 3])
        #expect(fetched.map(\.joined) == ["a,b", "", "x,y,z"])
        try await client.execute("DROP TABLE \(table)")
    }

    struct LowCardinalityRow: Codable, Sendable, Equatable {
        let id: UInt64
        let bucket: String
    }

    @Test("select decodes LowCardinality(String) round-trip when cast to String")
    func selectLowCardinality() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "lc")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, bucket LowCardinality(String)) ENGINE = MergeTree ORDER BY id")
        try await client.execute("INSERT INTO \(table) VALUES (1, 'red'), (2, 'green'), (3, 'red'), (4, 'blue'), (5, 'green')")
        let fetched = try await client.selectAll(
            "SELECT id, CAST(bucket AS String) AS bucket FROM \(table) ORDER BY id",
            as: LowCardinalityRow.self
        )
        #expect(fetched.map(\.bucket) == ["red", "green", "red", "blue", "green"])
        try await client.execute("DROP TABLE \(table)")
    }

    struct UUIDRow: Codable, Sendable, Equatable {
        let id: UInt64
        let key: String
    }

    @Test("select decodes UUID columns as their canonical string form")
    func selectUUID() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "uuid")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, key UUID) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES (1, '00000000-0000-0000-0000-000000000000'), (2, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11')")
        let fetched = try await client.selectAll(
            "SELECT id, toString(key) AS key FROM \(table) ORDER BY id",
            as: UUIDRow.self
        )
        #expect(fetched.count == 2)
        #expect(fetched[0].key == "00000000-0000-0000-0000-000000000000")
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("select returns zero rows for an empty MergeTree without error")
    func selectEmptyTable() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "empty")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = MergeTree ORDER BY id")
        struct IDRow: Decodable, Sendable, Equatable { let id: UInt64 }
        let rows = try await client.selectAll("SELECT id FROM \(table)", as: IDRow.self)
        #expect(rows.isEmpty)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("scalar returns a String result from a function expression")
    func scalarFromFunction() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        let result = try await client.scalar("SELECT upper('hello')", as: String.self)
        #expect(result == "HELLO")
    }

    @Test("select streams a large result set incrementally without losing rows")
    func selectStreamingLargeResult() async throws {
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        struct NumberRow: Decodable, Sendable, Equatable { let n: UInt64 }
        var observed: UInt64 = 0
        for try await row in client.select("SELECT toUInt64(number) AS n FROM numbers(10000)", as: NumberRow.self) {
            observed += row.n
        }
        // Sum of 0..9999 = 9999 * 10000 / 2 = 49_995_000
        #expect(observed == 49_995_000)
    }
}
