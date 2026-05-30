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

// Round-trip coverage for strings containing the tricky parts of the
// Unicode plane: multibyte BMP, surrogate-pair codepoints (emoji,
// astral characters), combining marks, zero-width joiners, mixed
// scripts, and embedded NULs. The Native protocol carries UTF-8
// payloads byte-for-byte, so anything that survives a UTF-8 round-trip
// in Swift must also survive INSERT + SELECT here.
@Suite(
    "Unicode SELECT / INSERT round-trip",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseUnicodeTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }
    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port)
    }

    private static func uniqueTableName(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    struct StringRow: Codable, Sendable, Equatable { let v: String }

    @Test("SELECT round-trips a CJK + emoji literal via scalar()")
    func scalarRoundTripsCJKAndEmoji() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let literal = "Hello 世界 🚀 🇯🇵 — testing\u{200D}swift"
        let escaped = literal.replacingOccurrences(of: "'", with: "''")
        let result = try await client.scalar("SELECT '\(escaped)'", as: String.self)
        #expect(result == literal)
    }

    @Test("SELECT round-trips a string of 4-byte emoji (surrogate pair codepoints)")
    func scalarRoundTripsAstralEmojiSequence() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let literal = "🎉🐍🦀🚀💯🤖"
        let escaped = literal.replacingOccurrences(of: "'", with: "''")
        let result = try await client.scalar("SELECT '\(escaped)'", as: String.self)
        #expect(result == literal)
    }

    @Test("INSERT + SELECT round-trips combining marks (precomposed vs decomposed)")
    func insertRoundTripsCombiningMarks() async throws {
        let table = Self.uniqueTableName("unicode_combining")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v String) ENGINE = Memory")
        let payloads = [
            "café",
            "cafe\u{0301}",
            "naïve",
            "\u{0300}\u{0301}\u{0302}",
        ]
        let rows = payloads.map { StringRow(v: $0) }
        let summary = try await client.insert(into: table, rows: rows)
        #expect(summary.rowsSent == payloads.count)
        let stored = try await client.selectAll("SELECT v FROM \(table) ORDER BY v", as: StringRow.self)
        let storedValues = Set(stored.map(\.v))
        for original in payloads {
            #expect(storedValues.contains(original), "missing payload \(original)")
        }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
    }

    @Test("INSERT + SELECT round-trips Right-To-Left scripts and ZWJ")
    func insertRoundTripsRTLAndZWJ() async throws {
        let table = Self.uniqueTableName("unicode_rtl_zwj")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v String) ENGINE = Memory")
        let payloads = [
            "السلام عليكم",
            "שלום עולם",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}",
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        ]
        let summary = try await client.insert(
            into: table,
            rows: payloads.map { StringRow(v: $0) }
        )
        #expect(summary.rowsSent == payloads.count)
        let stored = try await client.selectAll("SELECT v FROM \(table)", as: StringRow.self)
        let storedValues = Set(stored.map(\.v))
        for payload in payloads {
            #expect(storedValues.contains(payload))
        }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
    }

    @Test("INSERT preserves empty strings and strings with internal whitespace")
    func insertEmptyAndWhitespace() async throws {
        let table = Self.uniqueTableName("unicode_whitespace")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v String) ENGINE = Memory")
        let payloads = ["", " ", "\t", "\n", "  spaces  ", "tab\tinside"]
        _ = try await client.insert(into: table, rows: payloads.map { StringRow(v: $0) })
        let stored = try await client.selectAll("SELECT v FROM \(table)", as: StringRow.self)
        #expect(stored.count == payloads.count)
        let lengths = Set(stored.map { $0.v.count })
        // Six distinct payloads, but two collapse to length 1 (" " and
        // "\t" / "\n" are all single-codepoint), so we expect 4 distinct
        // lengths: 0, 1, 7 ("tab\tinside"), 10 ("  spaces  ").
        #expect(lengths.contains(0))
        #expect(lengths.contains(1))
        #expect(lengths.contains(10))
        try await client.execute("DROP TABLE IF EXISTS \(table)")
    }

    @Test("SELECT length() over a Unicode string returns byte length, not code-point count")
    func selectLengthReturnsByteCount() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let literal = "🚀"
        let escaped = literal.replacingOccurrences(of: "'", with: "''")
        let length = try await client.scalar(
            "SELECT toUInt64(length('\(escaped)'))",
            as: UInt64.self
        )
        // 🚀 (U+1F680) is encoded as 4 UTF-8 bytes.
        #expect(length == 4)
    }
}
