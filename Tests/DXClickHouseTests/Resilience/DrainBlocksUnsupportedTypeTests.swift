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

// drainBlocks() runs the same receive loop as a streaming select, sharing the
// close-on-broken-read recovery. An unsupported column type the drain path
// cannot size leaves the block partially read, so the loop must close the
// connection and the next operation must reconnect — the same guarantee the
// streaming select gives, verified here for the drain variant.
@Suite("drainBlocks closes the connection on an unsupported type so the next op reconnects")
struct DrainBlocksUnsupportedTypeTests {

    private static func unknownTypeBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("x", into: &bytes)
        ClickHouseWire.writeString("FooBar", into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: [0x07, 0x07, 0x07])
        return bytes
    }

    @Test("a drainBlocks of an unknown type errors, then a ping reconnects", .timeLimit(.minutes(1)))
    func drainBlocksReconnects() async throws {
        let server = FakeClickHouseServer()
        let hello = FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision)
        server.runScripts(
            serverHello: hello,
            scripts: [
                [.drainRequest, .reply(Self.unknownTypeBlock()), .drainRequest, .reply([0x04])],
                [.drainRequest, .reply([0x04])]
            ]
        )
        defer { server.stop() }

        let connection = try await AsyncClickHouseConnection(host: "127.0.0.1", port: server.port)
        try await connection.sendQuery("SELECT x")

        var drainFailed = false
        do {
            _ = try await connection.drainBlocks()
        } catch {
            drainFailed = true
        }
        #expect(drainFailed)

        try await connection.ping()

        await connection.close()
    }
}
