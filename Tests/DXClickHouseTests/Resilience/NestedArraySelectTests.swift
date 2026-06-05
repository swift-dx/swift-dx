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

// Array(Array(T)) is a common ClickHouse shape (adjacency lists, grouped
// values) that decodes into a Swift [[T]]. On the wire it is rowCount outer
// offsets, then totalOuter inner offsets, then the flattened innermost
// elements. The decoder groups elements by the inner offsets into inner
// arrays, then groups those by the outer offsets into per-row [[T]].
@Suite("Array(Array(T)) decodes into [[T]]")
struct NestedArraySelectTests {

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
        ClickHouseWire.writeString("v", into: &bytes)
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

    private struct IntRow: Decodable, Sendable, Equatable { let v: [[Int64]] }
    private struct StringRow: Decodable, Sendable, Equatable { let v: [[String]] }

    @Test("Array(Array(Int64)) decodes nested rows incl empty outer and empty inner", .timeLimit(.minutes(1)))
    func nestedInt64() async throws {
        // Row 0 [[1,2],[3]]; Row 1 [] (empty outer); Row 2 [[]] (one empty inner).
        var body = Self.uint64LE(2) + Self.uint64LE(2) + Self.uint64LE(3)     // outer offsets
        body += Self.uint64LE(2) + Self.uint64LE(3) + Self.uint64LE(3)        // inner offsets
        body += Self.int64LE(1) + Self.int64LE(2) + Self.int64LE(3)           // flattened elements
        var reply = Self.block(columnType: "Array(Array(Int64))", rowCount: 3, body: body)
        reply += Self.eos()
        let rows = try await Self.runSelect(reply: reply, as: IntRow.self)
        #expect(rows == [IntRow(v: [[1, 2], [3]]), IntRow(v: []), IntRow(v: [[]])])
    }

    @Test("Array(Array(String)) decodes nested variable-length rows", .timeLimit(.minutes(1)))
    func nestedString() async throws {
        // Row 0 [["a","b"],["c"]].
        var body = Self.uint64LE(2)                                 // outer offsets [2]
        body += Self.uint64LE(2) + Self.uint64LE(3)                      // inner offsets [2,3]
        body += Self.str("a") + Self.str("b") + Self.str("c")                // elements
        var reply = Self.block(columnType: "Array(Array(String))", rowCount: 1, body: body)
        reply += Self.eos()
        let rows = try await Self.runSelect(reply: reply, as: StringRow.self)
        #expect(rows == [StringRow(v: [["a", "b"], ["c"]])])
    }
}
