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

// The native ClickHouse JSON column type is not structurally decoded, so a
// SELECT of one surfaces an unsupported-type error. That error must arrive at
// a clean packet boundary: the connection copy path has to read the JSON
// column body (length-prefixed binary, like a String) off the wire so the
// trailing EndOfStream is consumed, rather than aborting mid-block and leaving
// stale bytes that desync the next request. A ping afterward must get its Pong.
@Suite("a native JSON SELECT errors without desyncing the connection")
struct NativeJSONSelectDesyncTests {

    private struct Row: Decodable, Sendable { let data: ClickHouseJSON }

    private static func jsonBlockThenEndOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("data", into: &bytes)
        ClickHouseWire.writeString("JSON", into: &bytes)
        bytes.append(0)
        ClickHouseWire.writeString("{\"a\":1}", into: &bytes)
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a ping after an unsupported-JSON SELECT gets its Pong, not a stale packet", .timeLimit(.minutes(1)))
    func pingSucceedsAfterUnsupportedJSON() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,
                .reply(Self.jsonBlockThenEndOfStream()),
                .drainRequest,
                .reply([0x04])
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var selectFailed = false
        do {
            _ = try await client.selectAll("SELECT data", as: Row.self)
        } catch {
            selectFailed = true
        }
        #expect(selectFailed)

        try await client.ping()

        await client.close()
    }
}
