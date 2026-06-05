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

// The supported JSON path stores JSON text in a String column: the encoder
// emits a String-typed column and a ClickHouseJSON field decodes a String
// column body back into its raw text bytes. Existing tests decode this in
// memory; a real SELECT must route the String body through the connection
// copy path (copyColumnBody) before the decoder lifts it into ClickHouseJSON.
@Suite("a JSON-text String column decodes into ClickHouseJSON via the copy path")
struct JSONStringColumnSelectTests {

    private struct Row: Decodable, Sendable, Equatable { let payload: ClickHouseJSON }

    private static func dataBlock(columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString("payload", into: &bytes)
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

    @Test("a String column carrying JSON text decodes into ClickHouseJSON", .timeLimit(.minutes(1)))
    func decodesThroughCopyPath() async throws {
        var body = Self.str("{\"a\":1}")
        body.append(contentsOf: Self.str("{\"b\":[2,3]}"))
        var reply = Self.dataBlock(columnType: "String", rowCount: 2, body: body)
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT payload FROM t", as: Row.self)
        await client.close()

        #expect(rows == [
            Row(payload: ClickHouseJSON("{\"a\":1}")),
            Row(payload: ClickHouseJSON("{\"b\":[2,3]}")),
        ])
    }
}
