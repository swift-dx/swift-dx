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

// Array(Nullable(T)) is a common ClickHouse shape — an array column whose
// elements may individually be NULL (optional tags, sparse measurements). On
// the wire it is rowCount cumulative offsets, then the flattened inner column
// as Nullable(T): a totalElements null mask followed by totalElements inner
// values (NULL slots carry a placeholder). The decoder lifts the mask onto the
// values and yields per-row [T?]. This exercises the new arrayOfNullable path
// end-to-end through the connection copy path for both a variable-width
// element (String) and a fixed-width element (Int64), with empty-array and
// all-NULL edges.
@Suite("Array(Nullable(T)) decodes into per-row arrays of optionals")
struct ArrayOfNullableSelectTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; ClickHouseWire.writeString(s, into: &out); return out
    }

    private static func block(columnName: String, columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString(columnName, into: &bytes)
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
        let rows = try await client.selectAll("SELECT v FROM t", as: type)
        await client.close()
        return rows
    }

    private struct StringRow: Decodable, Sendable, Equatable { let v: [String?] }
    private struct IntRow: Decodable, Sendable, Equatable { let v: [Int64?] }

    @Test("Array(Nullable(String)) lifts the null mask into per-row [String?]", .timeLimit(.minutes(1)))
    func nullableStringArray() async throws {
        // Two rows: ["a", NULL], then [] (empty). totalElements = 2.
        var body = Self.uint64LE(2) + Self.uint64LE(2)            // offsets [2, 2]
        body += [0x00, 0x01]                            // mask: present, NULL
        body += Self.str("a") + Self.str("")                      // values (NULL slot = placeholder "")
        var reply = Self.block(columnName: "v", columnType: "Array(Nullable(String))", rowCount: 2, body: body)
        reply += Self.eos()
        let rows = try await Self.runSelect(reply: reply, as: StringRow.self)
        #expect(rows == [StringRow(v: ["a", nil]), StringRow(v: [])])
    }

    @Test("Array(Nullable(Int64)) lifts the null mask into per-row [Int64?]", .timeLimit(.minutes(1)))
    func nullableInt64Array() async throws {
        // One row: [10, NULL, 30]. totalElements = 3.
        var body = Self.uint64LE(3)                          // offsets [3]
        body += [0x00, 0x01, 0x00]                      // mask
        body += Self.int64LE(10) + Self.int64LE(0) + Self.int64LE(30)  // values (NULL slot = placeholder 0)
        var reply = Self.block(columnName: "v", columnType: "Array(Nullable(Int64))", rowCount: 1, body: body)
        reply += Self.eos()
        let rows = try await Self.runSelect(reply: reply, as: IntRow.self)
        #expect(rows == [IntRow(v: [10, nil, 30])])
    }

    @Test("Array(Nullable(String)) all-NULL row decodes to all nils", .timeLimit(.minutes(1)))
    func allNullArray() async throws {
        var body = Self.uint64LE(2)                          // offsets [2]
        body += [0x01, 0x01]                            // mask: NULL, NULL
        body += Self.str("") + Self.str("")
        var reply = Self.block(columnName: "v", columnType: "Array(Nullable(String))", rowCount: 1, body: body)
        reply += Self.eos()
        let rows = try await Self.runSelect(reply: reply, as: StringRow.self)
        #expect(rows == [StringRow(v: [nil, nil])])
    }
}
