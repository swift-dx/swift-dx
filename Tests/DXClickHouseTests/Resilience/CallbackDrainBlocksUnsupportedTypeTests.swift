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

// The progress-callback drainBlocks runs the same receive loop as the plain
// drainBlocks, and must share the same close-on-broken-read recovery. An
// unsupported column type the drain path cannot size leaves the block partially
// read; the loop must close the connection so the leftover bytes are discarded
// and the next operation reconnects against a clean socket. Without that, the
// next read consumes the stale tail of the abandoned block and misreads it as a
// fresh packet. This pins the guarantee for the callback variant, which the
// plain variant already has.
@Suite("drainBlocks(onProgress:) closes the connection on an unsupported type so the next op reconnects")
struct CallbackDrainBlocksUnsupportedTypeTests {

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

    @Test("a callback drainBlocks of an unknown type errors, then a ping reconnects", .timeLimit(.minutes(1)))
    func callbackDrainBlocksReconnects() async throws {
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
            _ = try await connection.drainBlocks(onProgress: { _ in })
        } catch {
            drainFailed = true
        }
        #expect(drainFailed)

        try await connection.ping()

        await connection.close()
    }
}
