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

// Validates the INSERT (encode) wire path for the wide and composite types
// against a real server. The trap to avoid: a DXClickHouse insert followed by
// a DXClickHouse select of the SAME wide type can hide a bug that exists in
// both encode and decode (the two cancel). So each row is inserted through
// the Codable encode path, then read back through a TRUSTED decode — the
// server's own toString()/toInt32()/hex() rendered as String or Int, paths
// that are simple and independently proven. A wrong encode changes what the
// server stored and the trusted read-back disagrees.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct EncodeRoundTripIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: user, password: password, database: database)
    }

    private struct StringRow: Codable, Sendable, Equatable { let s: String }

    private static func uniqueTable(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    @Test("Decimal of every width inserts with byte-correct values", .timeLimit(.minutes(1)))
    func decimalEncode() async throws {
        struct Row: Codable, Sendable { let d: ClickHouseDecimal }
        let client = try await Self.makeClient()
        let cases: [(String, UInt8, UInt8, String)] = [
            ("Decimal(9, 2)", 9, 2, "-123.45"),
            ("Decimal(18, 6)", 18, 6, "-1234567.891234"),
            ("Decimal(38, 10)", 38, 10, "12345678901234567890.123456789"),
            ("Decimal(76, 20)", 76, 20, "-123456789012345678901234567890.1234567890123456789"),
        ]
        for (index, testCase) in cases.enumerated() {
            let table = Self.uniqueTable("dx_encdec_\(index)")
            try await client.execute("CREATE TABLE \(table) (d \(testCase.0)) ENGINE = Memory")
            let value = try ClickHouseDecimal(testCase.3, precision: testCase.1, scale: testCase.2)
            _ = try await client.insert(into: table, rows: [Row(d: value)])
            let back = try await client.selectAll("SELECT toString(d) AS s FROM \(table)", as: StringRow.self)
            #expect(back == [StringRow(s: testCase.3)], "Decimal \(testCase.0) encode mismatch for \(testCase.3): got \(back)")
            try await client.execute("DROP TABLE \(table)")
        }
        await client.close()
    }

    @Test("Int128/Int256/UInt256 insert with byte-correct values", .timeLimit(.minutes(1)))
    func wideIntEncode() async throws {
        struct I128 : Codable, Sendable { let n: ClickHouseInt128 }
        struct I256 : Codable, Sendable { let n: ClickHouseInt256 }
        struct U256 : Codable, Sendable { let n: ClickHouseUInt256 }
        let client = try await Self.makeClient()

        let t128 = Self.uniqueTable("dx_enc128")
        try await client.execute("CREATE TABLE \(t128) (n Int128) ENGINE = Memory")
        let min128 = Int128("-170141183460469231731687303715884105728")!
        _ = try await client.insert(into: t128, rows: [I128(n: .init(min128)), I128(n: .init(-1)), I128(n: .init(42))])
        let r128 = try await client.selectAll("SELECT toString(n) AS s FROM \(t128) ORDER BY n", as: StringRow.self)
        #expect(r128.map(\.s) == ["-170141183460469231731687303715884105728", "-1", "42"])
        try await client.execute("DROP TABLE \(t128)")

        let t256 = Self.uniqueTable("dx_enc256")
        try await client.execute("CREATE TABLE \(t256) (n Int256) ENGINE = Memory")
        _ = try await client.insert(into: t256, rows: [I256(n: .init(-1)), I256(n: .init(123456789))])
        let r256 = try await client.selectAll("SELECT toString(n) AS s FROM \(t256) ORDER BY n", as: StringRow.self)
        #expect(r256.map(\.s) == ["-1", "123456789"])
        try await client.execute("DROP TABLE \(t256)")

        let tu256 = Self.uniqueTable("dx_encu256")
        try await client.execute("CREATE TABLE \(tu256) (n UInt256) ENGINE = Memory")
        // 2^192 via the high limb, exercising limb ordering on encode.
        _ = try await client.insert(into: tu256, rows: [U256(n: .init(limb0: 0, limb1: 0, limb2: 0, limb3: 1)), U256(n: .init(7))])
        let ru256 = try await client.selectAll("SELECT toString(n) AS s FROM \(tu256) ORDER BY n", as: StringRow.self)
        #expect(ru256.map(\.s) == ["7", "6277101735386680763835789423207666416102355444464034512896"])
        try await client.execute("DROP TABLE \(tu256)")
        await client.close()
    }

    @Test("IPv6, Date32, and Enum16 insert with byte-correct values", .timeLimit(.minutes(1)))
    func miscEncode() async throws {
        struct IP : Codable, Sendable { let ip: ClickHouseIPv6 }
        struct D32 : Codable, Sendable { let d: ClickHouseDate32 }
        struct E16 : Codable, Sendable { let e: ClickHouseEnum16 }
        let client = try await Self.makeClient()

        let tip = Self.uniqueTable("dx_encip6")
        try await client.execute("CREATE TABLE \(tip) (ip IPv6) ENGINE = Memory")
        _ = try await client.insert(into: tip, rows: [IP(ip: try .init("2001:db8::dead:beef"))])
        let rip = try await client.selectAll("SELECT hex(ip) AS s FROM \(tip)", as: StringRow.self)
        #expect(rip == [StringRow(s: "20010DB80000000000000000DEADBEEF")])
        try await client.execute("DROP TABLE \(tip)")

        let td = Self.uniqueTable("dx_encd32")
        try await client.execute("CREATE TABLE \(td) (d Date32) ENGINE = Memory")
        _ = try await client.insert(into: td, rows: [D32(d: .init(days: -7243)), D32(d: .init(days: 20606))])
        let rd = try await client.selectAll("SELECT toInt32(d) AS s FROM \(td) ORDER BY d", as: TrustedIntRow.self)
        #expect(rd.map(\.s) == [-7243, 20606])
        try await client.execute("DROP TABLE \(td)")

        let mapping = [ClickHouseEnumPair(name: "alpha", value: -5), ClickHouseEnumPair(name: "beta", value: 1000)]
        let te = Self.uniqueTable("dx_ence16")
        try await client.execute("CREATE TABLE \(te) (e Enum16('alpha' = -5, 'beta' = 1000)) ENGINE = Memory")
        _ = try await client.insert(into: te, rows: [E16(e: .init(value: -5, mapping: mapping)), E16(e: .init(value: 1000, mapping: mapping))])
        let re = try await client.selectAll("SELECT toInt32(e) AS s FROM \(te) ORDER BY e", as: TrustedIntRow.self)
        #expect(re.map(\.s) == [-5, 1000])
        try await client.execute("DROP TABLE \(te)")
        await client.close()
    }

    private struct TrustedIntRow: Codable, Sendable { let s: Int32 }

    @Test("Array(Nullable), nested Array, and Map(Nullable) insert correctly", .timeLimit(.minutes(1)))
    func compositeEncode() async throws {
        struct ANull : Codable, Sendable { let v: [Int64?] }
        struct Nest : Codable, Sendable { let g: [[Int64]] }
        struct MNull : Codable, Sendable { let m: [String: String?] }
        let client = try await Self.makeClient()

        let ta = Self.uniqueTable("dx_encanull")
        try await client.execute("CREATE TABLE \(ta) (v Array(Nullable(Int64))) ENGINE = Memory")
        _ = try await client.insert(into: ta, rows: [ANull(v: [1, nil, 3]), ANull(v: []), ANull(v: [nil])])
        let ra = try await client.selectAll("SELECT toString(v) AS s FROM \(ta)", as: StringRow.self)
        #expect(ra.map(\.s) == ["[1,NULL,3]", "[]", "[NULL]"])
        try await client.execute("DROP TABLE \(ta)")

        let tn = Self.uniqueTable("dx_encnest")
        try await client.execute("CREATE TABLE \(tn) (g Array(Array(Int64))) ENGINE = Memory")
        _ = try await client.insert(into: tn, rows: [Nest(g: [[1, 2], [3]]), Nest(g: []), Nest(g: [[], [4, 5]])])
        let rn = try await client.selectAll("SELECT toString(g) AS s FROM \(tn)", as: StringRow.self)
        #expect(rn.map(\.s) == ["[[1,2],[3]]", "[]", "[[],[4,5]]"])
        try await client.execute("DROP TABLE \(tn)")

        let tm = Self.uniqueTable("dx_encmnull")
        try await client.execute("CREATE TABLE \(tm) (m Map(String, Nullable(String))) ENGINE = Memory")
        _ = try await client.insert(into: tm, rows: [MNull(m: ["k1": "v1"]), MNull(m: [:])])
        let rm = try await client.selectAll("SELECT toString(m) AS s FROM \(tm) ORDER BY length(m) DESC", as: StringRow.self)
        #expect(rm.map(\.s) == ["{'k1':'v1'}", "{}"])
        try await client.execute("DROP TABLE \(tm)")
        await client.close()
    }
}
