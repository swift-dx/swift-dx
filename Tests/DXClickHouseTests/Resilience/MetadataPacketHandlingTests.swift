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

// A real ClickHouse server interleaves metadata packets into a query
// response: TimezoneUpdate (17) carrying the session timezone, and
// TableColumns (11) describing the result columns, both arriving before the
// data blocks. Every receive loop must read these off the wire and drop them
// rather than mistaking them for result rows or rejecting them as unexpected.
// These packets are exercised here through the real receive loops end to end.
@Suite("metadata packets are consumed, not surfaced as rows")
struct MetadataPacketHandlingTests {

    private struct Row: Decodable, Sendable, Equatable { let id: UInt8 }

    private static func timezoneUpdate() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(17, into: &bytes)
        ClickHouseWire.writeString("UTC", into: &bytes)
        return bytes
    }

    private static func tableColumns() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(11, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeString("id UInt8", into: &bytes)
        return bytes
    }

    private static func oneRowBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("id", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        bytes.append(1)
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    private static func metadataThenRow() -> [UInt8] {
        timezoneUpdate() + tableColumns() + oneRowBlock() + endOfStream()
    }

    @Test("drainBlocks skips TimezoneUpdate and TableColumns", .timeLimit(.minutes(1)))
    func drainBlocksSkipsMetadata() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.metadataThenRow())]
        )
        defer { server.stop() }

        let connection = try await AsyncClickHouseConnection(host: "127.0.0.1", port: server.port)
        try await connection.sendQuery("SELECT id FROM t")
        let rows = try await connection.drainBlocks()
        await connection.close()

        #expect(rows == 1)
    }

    @Test("selectAll skips TimezoneUpdate and TableColumns", .timeLimit(.minutes(1)))
    func selectAllSkipsMetadata() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.metadataThenRow())]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT id FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(id: 1)])
    }
}
