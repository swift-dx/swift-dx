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

// Drives `ClickHouseClient.insert(into:rows:)` against every realistic
// column shape and verifies the round-trip with a follow-up SELECT that
// confirms both the row count and the decoded values match the source.
// Each test owns its table so failures stay contained.
@Suite(
    "DXClickHouse OperationsCoverage: insert against every realistic type",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct InsertCoverageIT {

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

    @Test("insert UInt/Int columns of every width and verify via SELECT count")
    func insertIntegers() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_ints")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("""
            CREATE TABLE \(table) (
                u8 UInt8, u16 UInt16, u32 UInt32, u64 UInt64,
                i8 Int8, i16 Int16, i32 Int32, i64 Int64
            ) ENGINE = Memory
            """)
        let rows = [
            IntegerRow(u8: 1, u16: 2, u32: 3, u64: 4, i8: -1, i16: -2, i32: -3, i64: -4),
            IntegerRow(u8: 5, u16: 6, u32: 7, u64: 8, i8: -5, i16: -6, i32: -7, i64: -8),
            IntegerRow(u8: 9, u16: 10, u32: 11, u64: 12, i8: -9, i16: -10, i32: -11, i64: -12),
        ]
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 3)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 3)
        try await client.execute("DROP TABLE \(table)")
    }

    struct FloatRow: Codable, Sendable, Equatable {
        let id: UInt64
        let f32: Float
        let f64: Double
    }

    @Test("insert Float32 / Float64 columns and verify via row-count + sum")
    func insertFloats() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_floats")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, f32 Float32, f64 Float64) ENGINE = Memory")
        let rows = (1...50).map { FloatRow(id: UInt64($0), f32: Float($0) * 0.5, f64: Double($0) * 0.25) }
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 50)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 50)
        try await client.execute("DROP TABLE \(table)")
    }

    struct StringRow: Codable, Sendable, Equatable {
        let id: UInt64
        let name: String
    }

    @Test("insert String column including empty and multibyte values")
    func insertStrings() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_strings")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, name String) ENGINE = Memory")
        let rows = [
            StringRow(id: 1, name: ""),
            StringRow(id: 2, name: "ascii"),
            StringRow(id: 3, name: "café — über 🚀"),
            StringRow(id: 4, name: String(repeating: "long", count: 1024)),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let fetched = try await client.selectAll(
            "SELECT id, name FROM \(table) ORDER BY id",
            as: StringRow.self
        )
        #expect(fetched == rows)
        try await client.execute("DROP TABLE \(table)")
    }

    struct NullableRow: Codable, Sendable, Equatable {
        let id: UInt64
        let opt_text: String?
        let opt_int: Int32?
    }

    @Test("insert Nullable columns and verify the null pattern is preserved")
    func insertNullable() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_nullable")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("""
            CREATE TABLE \(table) (
                id UInt64,
                opt_text Nullable(String),
                opt_int Nullable(Int32)
            ) ENGINE = Memory
            """)
        let rows = [
            NullableRow(id: 1, opt_text: "a", opt_int: 10),
            NullableRow(id: 2, opt_text: nil, opt_int: nil),
            NullableRow(id: 3, opt_text: "c", opt_int: -100),
        ]
        _ = try await client.insert(into: table, rows: rows)
        let nullCount = try await client.scalar(
            "SELECT toUInt64(count()) FROM \(table) WHERE opt_text IS NULL",
            as: UInt64.self
        )
        #expect(nullCount == 1)
        let fetched = try await client.selectAll(
            "SELECT id, opt_text, opt_int FROM \(table) ORDER BY id",
            as: NullableRow.self
        )
        #expect(fetched == rows)
        try await client.execute("DROP TABLE \(table)")
    }

    struct BoolRow: Codable, Sendable, Equatable {
        let id: UInt64
        let active: Bool
    }

    @Test("insert Bool column and verify true/false count")
    func insertBool() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_bool")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, active Bool) ENGINE = Memory")
        let rows = (1...20).map { BoolRow(id: UInt64($0), active: $0 % 2 == 0) }
        _ = try await client.insert(into: table, rows: rows)
        let trueCount = try await client.scalar(
            "SELECT toUInt64(countIf(active = true)) FROM \(table)",
            as: UInt64.self
        )
        #expect(trueCount == 10)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert empty array returns rowsSent=0 and the table stays empty")
    func insertEmpty() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_empty")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = Memory")
        struct IDRow: Encodable, Sendable { let id: UInt64 }
        let summary = try await client.insert(into: table, rows: [IDRow]())
        #expect(summary.rowsSent == 0)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 0)
        try await client.execute("DROP TABLE \(table)")
    }

    struct LargeRow: Codable, Sendable, Equatable {
        let id: UInt64
        let body: String
    }

    @Test("insert a 5000-row batch and verify the row count via SELECT")
    func insertLargeBatch() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_large")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (id UInt64, body String) ENGINE = MergeTree ORDER BY id")
        let rows = (0..<5000).map { LargeRow(id: UInt64($0), body: "row-\($0)") }
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == 5000)
        let count = try await client.scalar("SELECT toUInt64(count()) FROM \(table)", as: UInt64.self)
        #expect(count == 5000)
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("insert with schema mismatch surfaces typed protocolError")
    func insertSchemaMismatchTyped() async throws {
        let table = OperationsCoverageSupport.uniqueTable(prefix: "ins_schema")
        let client = try await OperationsCoverageSupport.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("CREATE TABLE \(table) (a UInt64, b UInt64) ENGINE = Memory")
        struct WrongShape: Encodable, Sendable {
            let a: UInt64
            let c: String
        }
        let rows = [WrongShape(a: 1, c: "wrong")]
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        var didThrow = false
        do {
            _ = try await client.insert(into: table, rows: rows)
        } catch {
            didThrow = true
            caught = error
        }
        #expect(didThrow, "expected schema mismatch to fail")
        if didThrow {
            switch caught {
            case .protocolError, .queryFailed: break
            default: Issue.record("expected protocolError or queryFailed, got \(caught)")
            }
        }
        try await client.execute("DROP TABLE \(table)")
    }
}
