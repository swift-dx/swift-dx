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

// The block-skip path (used to drop Totals/Extremes blocks) reads String
// column lengths through its own inline uvarint reader, separate from the
// packet-stream reader. That reader had the same overflow hole: a ten-byte
// length varint with a tenth byte above one silently collapsed to a wrong
// (smaller) value instead of throwing, so a malformed length was accepted
// and the skip consumed the wrong number of bytes — desyncing the stream.
// The skip reader must reject the overflow exactly like the others.
@Suite("the block-skip string reader rejects a ten-byte overflow")
struct SkipStringRowsOverflowTests {

    private struct Row: Decodable, Sendable, Equatable { let value: UInt8 }

    // A normal one-row UInt8 data block (packet type 1).
    private static func dataBlock(value: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("value", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        bytes.append(value)
        return bytes
    }

    // A Totals block (packet type 7) with one String column whose single
    // row's length is an overflowing ten-byte varint (0x80×9 + 0x02). The
    // client skips this block, routing the malformed length through the
    // skip reader.
    private static func totalsBlockWithOverflowingStringLength() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("s", into: &bytes)
        ClickHouseWire.writeString("String", into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: Array(repeating: 0x80, count: 9) + [0x02])
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a malformed skipped-string length fails as an overflow, not a desync", .timeLimit(.minutes(1)))
    func rejectsOverflow() async throws {
        var reply = Self.dataBlock(value: 10)
        reply.append(contentsOf: Self.totalsBlockWithOverflowingStringLength())
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        defer { Task { await client.close() } }

        var thrownStage = ""
        do {
            _ = try await client.selectAll("SELECT value FROM t WITH TOTALS", as: Row.self)
            Issue.record("expected the malformed skipped-string length to throw")
        } catch {
            if case .protocolError(let stage, _) = error { thrownStage = stage }
        }

        #expect(thrownStage == "uvarint")
    }
}
