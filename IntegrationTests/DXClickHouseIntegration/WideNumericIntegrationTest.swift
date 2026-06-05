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

// Decimal and the 128/256-bit integers are the highest-risk decode paths:
// their two's-complement sign extension and limb ordering were only ever
// exercised against fabricated wire payloads. Here the server is the oracle.
// Each row carries the typed column AND the server's own toString() of the
// same value; the decoded wrapper's description must equal what the server
// rendered. A wrong byte, wrong limb order, or missing sign extension makes
// the two disagree.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct WideNumericIntegrationTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: user, password: password, database: database)
    }

    // ClickHouse's Decimal toString() strips trailing fractional zeros
    // (1.50 -> "1.5", 1.00 -> "1"), whereas DXClickHouse renders the full
    // declared scale (1.50 -> "1.50"). Both denote the same value; the byte
    // correctness is what matters. Normalise both to the trailing-zero-free
    // form before comparing.
    private static func stripTrailingZeros(_ value: String) -> String {
        guard value.contains(".") else { return value }
        var result = value
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    private struct DecimalRow: Codable, Sendable {
        let d: ClickHouseDecimal
        let s: String
    }

    private struct Int128Row: Codable, Sendable {
        let n: ClickHouseInt128
        let s: String
    }

    private struct Int256Row: Codable, Sendable {
        let n: ClickHouseInt256
        let s: String
    }

    private struct UInt256Row: Codable, Sendable {
        let n: ClickHouseUInt256
        let s: String
    }

    @Test("Decimal of every width, positive and negative, decodes to the server's rendering", .timeLimit(.minutes(1)))
    func decimals() async throws {
        let client = try await Self.makeClient()
        // (column type, literal) covering D32/D64/D128/D256 incl. negatives and edge magnitudes.
        let cases: [(String, String)] = [
            ("Decimal(9, 2)", "-123.45"),
            ("Decimal(9, 2)", "123.45"),
            ("Decimal(9, 4)", "0.0001"),
            ("Decimal(18, 6)", "-1234567.891234"),
            ("Decimal(18, 0)", "999999999999999999"),
            ("Decimal(38, 10)", "-12345678901234567890.1234567890"),
            ("Decimal(38, 0)", "99999999999999999999999999999999999999"),
            ("Decimal(76, 20)", "-123456789012345678901234567890.12345678901234567890"),
        ]
        for (index, testCase) in cases.enumerated() {
            let table = "dx_dec_\(index)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
            try await client.execute("CREATE TABLE \(table) (d \(testCase.0)) ENGINE = Memory")
            try await client.execute("INSERT INTO \(table) VALUES (\(testCase.1))")
            let rows = try await client.selectAll("SELECT d, toString(d) AS s FROM \(table)", as: DecimalRow.self)
            #expect(rows.count == 1)
            #expect(Self.stripTrailingZeros(rows[0].d.description) == rows[0].s, "type \(testCase.0): decoded \(rows[0].d.description) but server rendered \(rows[0].s)")
            try await client.execute("DROP TABLE \(table)")
        }
        await client.close()
    }

    @Test("Int128 positive and negative extremes decode to the server's rendering", .timeLimit(.minutes(1)))
    func int128() async throws {
        let client = try await Self.makeClient()
        let literals = ["0", "-1", "1", "170141183460469231731687303715884105727", "-170141183460469231731687303715884105728"]
        for (index, literal) in literals.enumerated() {
            let table = "dx_i128_\(index)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
            try await client.execute("CREATE TABLE \(table) (n Int128) ENGINE = Memory")
            try await client.execute("INSERT INTO \(table) VALUES (\(literal))")
            let rows = try await client.selectAll("SELECT n, toString(n) AS s FROM \(table)", as: Int128Row.self)
            #expect(rows[0].n.description == rows[0].s, "Int128 \(literal): decoded \(rows[0].n.description) vs server \(rows[0].s)")
            try await client.execute("DROP TABLE \(table)")
        }
        await client.close()
    }

    @Test("Int256 and UInt256 extremes decode to the server's rendering", .timeLimit(.minutes(1)))
    func wide256() async throws {
        let client = try await Self.makeClient()
        let signed = ["0", "-1", "57896044618658097711785492504343953926634992332820282019728792003956564819967", "-57896044618658097711785492504343953926634992332820282019728792003956564819968"]
        for (index, literal) in signed.enumerated() {
            let table = "dx_i256_\(index)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
            try await client.execute("CREATE TABLE \(table) (n Int256) ENGINE = Memory")
            try await client.execute("INSERT INTO \(table) VALUES (\(literal))")
            let rows = try await client.selectAll("SELECT n, toString(n) AS s FROM \(table)", as: Int256Row.self)
            #expect(rows[0].n.description == rows[0].s, "Int256 \(literal): decoded \(rows[0].n.description) vs server \(rows[0].s)")
            try await client.execute("DROP TABLE \(table)")
        }
        let unsigned = ["0", "1", "115792089237316195423570985008687907853269984665640564039457584007913129639935"]
        for (index, literal) in unsigned.enumerated() {
            let table = "dx_u256_\(index)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
            try await client.execute("CREATE TABLE \(table) (n UInt256) ENGINE = Memory")
            try await client.execute("INSERT INTO \(table) VALUES (\(literal))")
            let rows = try await client.selectAll("SELECT n, toString(n) AS s FROM \(table)", as: UInt256Row.self)
            #expect(rows[0].n.description == rows[0].s, "UInt256 \(literal): decoded \(rows[0].n.description) vs server \(rows[0].s)")
            try await client.execute("DROP TABLE \(table)")
        }
        await client.close()
    }
}
