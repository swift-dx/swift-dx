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

// Date, Date32 (including pre-epoch negative day counts), Enum16, and IPv6
// decode straight from a real server. Each row carries the typed wrapper and
// the server's own raw integer / byte projection of the same value, so the
// comparison is exact and free of any rendering convention.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct TemporalAndMiscIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: user, password: password, database: database)
    }

    private struct DateRow: Codable, Sendable {
        let d: ClickHouseDate
        let days: UInt16
    }

    private struct Date32Row: Codable, Sendable {
        let d: ClickHouseDate32
        let days: Int32
    }

    private struct Enum16Row: Codable, Sendable {
        let e: ClickHouseEnum16
        let v: Int16
    }

    private struct IPv6Row: Codable, Sendable {
        let ip: ClickHouseIPv6
        let h: String
    }

    private struct FixedRow: Codable, Sendable {
        let f: ClickHouseFixedString
        let h: String
    }

    @Test("Date decodes with the server's day count", .timeLimit(.minutes(1)))
    func date() async throws {
        let client = try await Self.makeClient()
        let table = "dx_date_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (d Date) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES ('1970-01-01'), ('2026-06-02'), ('2149-06-06')")
        let rows = try await client.selectAll("SELECT d, toUInt16(d) AS days FROM \(table) ORDER BY d", as: DateRow.self)
        #expect(!rows.isEmpty)
        for row in rows { #expect(row.d.days == row.days, "Date day count mismatch: \(row.d.days) vs \(row.days)") }
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("Date32 decodes pre-epoch negative day counts", .timeLimit(.minutes(1)))
    func date32() async throws {
        let client = try await Self.makeClient()
        let table = "dx_date32_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (d Date32) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES ('1900-01-01'), ('1950-03-04'), ('1970-01-01'), ('2100-12-31')")
        let rows = try await client.selectAll("SELECT d, toInt32(d) AS days FROM \(table) ORDER BY d", as: Date32Row.self)
        #expect(rows.contains { $0.days < 0 })
        for row in rows { #expect(row.d.days == row.days, "Date32 day count mismatch: \(row.d.days) vs \(row.days)") }
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("Enum16 decodes the server's numeric value", .timeLimit(.minutes(1)))
    func enum16() async throws {
        let client = try await Self.makeClient()
        let table = "dx_enum16_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (e Enum16('alpha' = -5, 'beta' = 1000, 'gamma' = 30000)) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES ('alpha'), ('beta'), ('gamma')")
        let rows = try await client.selectAll("SELECT e, toInt16(e) AS v FROM \(table) ORDER BY v", as: Enum16Row.self)
        #expect(rows.map(\.v) == [-5, 1000, 30000])
        for row in rows { #expect(row.e.value == row.v, "Enum16 value mismatch: \(row.e.value) vs \(row.v)") }
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("IPv6 decodes byte-for-byte", .timeLimit(.minutes(1)))
    func ipv6() async throws {
        let client = try await Self.makeClient()
        let table = "dx_ipv6_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (ip IPv6) ENGINE = Memory")
        try await client.execute("INSERT INTO \(table) VALUES ('::1'), ('2001:db8::1'), ('fe80::1ff:fe23:4567:890a'), ('::ffff:192.168.1.1')")
        let rows = try await client.selectAll("SELECT ip, hex(ip) AS h FROM \(table)", as: IPv6Row.self)
        #expect(rows.count == 4)
        for row in rows {
            let decodedHex = row.ip.bytes.map { String(format: "%02X", $0) }.joined()
            #expect(decodedHex == row.h, "IPv6 byte mismatch: \(decodedHex) vs \(row.h)")
        }
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("FixedString preserves embedded NUL and binary bytes", .timeLimit(.minutes(1)))
    func fixedStringBinary() async throws {
        let client = try await Self.makeClient()
        let table = "dx_fixbin_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (f FixedString(6)) ENGINE = Memory")
        // 'ab\0\xFF\x01z' — embedded NUL and high byte, must round-trip intact.
        try await client.execute("INSERT INTO \(table) VALUES (unhex('6162001020FF'))")
        let rows = try await client.selectAll("SELECT f, hex(f) AS h FROM \(table)", as: FixedRow.self)
        #expect(rows.count == 1)
        let decodedHex = rows[0].f.bytes.map { String(format: "%02X", $0) }.joined()
        #expect(decodedHex == rows[0].h, "FixedString byte mismatch: \(decodedHex) vs \(rows[0].h)")
        #expect(rows[0].f.bytes.count == 6)
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
