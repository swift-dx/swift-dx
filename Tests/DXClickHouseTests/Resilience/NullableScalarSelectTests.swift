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

// Nullable columns are ubiquitous. On the wire a Nullable(T) column is a
// rowCount-byte null mask (1 = NULL) followed by the inner T values. The
// connection copy path lifts the mask and the inner column out of the arena
// before the decoder maps null rows to nil. Existing tests decode this in
// memory; a real SELECT must route it through copyColumnBody, exercised here
// for the two most common inner types.
@Suite("Nullable scalar columns decode through the connection copy path")
struct NullableScalarSelectTests {

    private static func dataBlock(columnName: String, columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
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

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        ClickHouseWire.writeString(s, into: &out)
        return out
    }

    private struct IntRow: Decodable, Sendable, Equatable { let v: UInt8? }
    private struct StringRow: Decodable, Sendable, Equatable { let s: String? }

    @Test("Nullable(UInt8) maps the null mask to nil via selectAll", .timeLimit(.minutes(1)))
    func nullableUInt8() async throws {
        // mask 0,1,0 then values 5,0,3 — row 1 is NULL.
        let body: [UInt8] = [0x00, 0x01, 0x00, 0x05, 0x00, 0x03]
        var reply = Self.dataBlock(columnName: "v", columnType: "Nullable(UInt8)", rowCount: 3, body: body)
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT v FROM t", as: IntRow.self)
        await client.close()

        #expect(rows == [IntRow(v: 5), IntRow(v: nil), IntRow(v: 3)])
    }

    @Test("Nullable(String) maps the null mask to nil via selectAll", .timeLimit(.minutes(1)))
    func nullableString() async throws {
        var body: [UInt8] = [0x00, 0x01, 0x00]
        body.append(contentsOf: Self.str("a"))
        body.append(contentsOf: Self.str(""))
        body.append(contentsOf: Self.str("c"))
        var reply = Self.dataBlock(columnName: "s", columnType: "Nullable(String)", rowCount: 3, body: body)
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT s FROM t", as: StringRow.self)
        await client.close()

        #expect(rows == [StringRow(s: "a"), StringRow(s: nil), StringRow(s: "c")])
    }

    @Test("Nullable(String) distinguishes a non-null empty string from NULL", .timeLimit(.minutes(1)))
    func nullableStringEmptyVsNull() async throws {
        // mask 1,0,0 — row 0 is NULL, row 1 is the empty string (not null).
        var body: [UInt8] = [0x01, 0x00, 0x00]
        body.append(contentsOf: Self.str(""))
        body.append(contentsOf: Self.str(""))
        body.append(contentsOf: Self.str("x"))
        var reply = Self.dataBlock(columnName: "s", columnType: "Nullable(String)", rowCount: 3, body: body)
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT s FROM t", as: StringRow.self)
        await client.close()

        #expect(rows == [StringRow(s: nil), StringRow(s: ""), StringRow(s: "x")])
    }
}
