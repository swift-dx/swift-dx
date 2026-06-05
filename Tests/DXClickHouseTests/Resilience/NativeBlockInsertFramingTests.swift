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

// The native-block INSERT path sends the caller's block bytes and then the
// empty terminator block. Sending those as two separate writes lets them land
// in separate TCP segments, so back-to-back inserts can interleave the
// terminator of one insert with the next request and desync the stream
// (observed as a broken pipe). The two must leave as one contiguous write so
// the framing is deterministic regardless of how the peer reads.
@Suite("native-block inserts frame the block and terminator as one write")
struct NativeBlockInsertFramingTests {

    private static func sampleBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeString("v", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        return bytes
    }

    private static func insertSequence() -> [FakeClickHouseServer.ScriptStep] {
        [.drainRequest, .reply(sampleBlock()), .drainRequest, .reply([0x05])]
    }

    @Test("two back-to-back native-block inserts stay framed", .timeLimit(.minutes(1)))
    func backToBackNativeBlockInserts() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: Self.insertSequence() + Self.insertSequence()
        )
        defer { server.stop() }

        let block: [UInt8] = Self.sampleBlock()
        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let first = try await client.insertNativeBlock(into: "t", columnList: "(v)", nativeBlockBytes: block)
        let second = try await client.insertNativeBlock(into: "t", columnList: "(v)", nativeBlockBytes: block)
        await client.close()

        #expect(first.blocksSent == 1)
        #expect(second.blocksSent == 1)
    }
}
