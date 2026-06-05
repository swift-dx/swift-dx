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

@testable import DXClickHouse
import Foundation
import Testing

// Map(K, Nullable(V)) — a map whose values may individually be NULL — decodes
// into a Swift [K: V?]. On the wire it is rowCount offsets, the flattened keys,
// then the flattened values as a Nullable(V) column (null mask + values). The
// decoder lifts the mask onto the values and groups both by the offsets.
@Suite("Map(String, Nullable(V)) decodes into [String: V?]")
struct MapNullableValueSelectTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; ClickHouseWire.writeString(s, into: &out); return out
    }
    private static func block(columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString("m", into: &bytes)
        ClickHouseWire.writeString(columnType, into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: body)
        return bytes
    }
    private static func eos() -> [UInt8] {
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }
    private static func runSelect<T: Decodable & Sendable>(reply: [UInt8], as type: T.Type) async throws -> [T] {
        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }
        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT m FROM t", as: type)
        await client.close()
        return rows
    }

    private struct StringRow: Decodable, Sendable, Equatable { let m: [String: String?] }
    private struct IntRow: Decodable, Sendable, Equatable { let m: [String: Int64?] }

    @Test("Map(String, Nullable(String)) lifts the null mask into [String: String?]", .timeLimit(.minutes(1)))
    func nullableStringValues() async throws {
        // Row 0 {a: "x", b: NULL}; Row 1 {} (empty). Offsets [2, 2].
        var body = Self.uint64LE(2) + Self.uint64LE(2)
        body += Self.str("a") + Self.str("b")          // keys
        body += [0x00, 0x01]                  // value null mask: present, NULL
        body += Self.str("x") + Self.str("")            // values (placeholder for NULL)
        var reply = Self.block(columnType: "Map(String, Nullable(String))", rowCount: 2, body: body)
        reply += Self.eos()
        let rows = try await Self.runSelect(reply: reply, as: StringRow.self)
        #expect(rows == [StringRow(m: ["a": "x", "b": nil]), StringRow(m: [:])])
    }

    @Test("Map(String, Nullable(Int64)) lifts the null mask into [String: Int64?]", .timeLimit(.minutes(1)))
    func nullableIntValues() async throws {
        // Row 0 {k1: 10, k2: NULL}. Offsets [2].
        var body = Self.uint64LE(2)
        body += Self.str("k1") + Self.str("k2")
        body += [0x00, 0x01]
        body += Self.int64LE(10) + Self.int64LE(0)
        var reply = Self.block(columnType: "Map(String, Nullable(Int64))", rowCount: 1, body: body)
        reply += Self.eos()
        let rows = try await Self.runSelect(reply: reply, as: IntRow.self)
        #expect(rows == [IntRow(m: ["k1": 10, "k2": nil])])
    }
}
