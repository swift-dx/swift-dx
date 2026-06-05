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

// A real SELECT over a non-trivial result returns several data blocks: a
// leading 0-row header block carrying only the schema, then one or more data
// blocks of up to ~65505 rows each, then EndOfStream. The client must skip the
// empty header block, decode every data block against its own per-block header,
// and concatenate the rows in arrival order with no cross-block byte bleed in
// the copy arena. Every other FakeServer test sends a single block; this pins
// the multi-block contract that production large results depend on.
@Suite("multi-block SELECT results concatenate in order")
struct MultiBlockSelectTests {

    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; ClickHouseWire.writeString(s, into: &out); return out
    }

    // A Data packet for a single String column. rowCount 0 emits the schema
    // header with no body (the server's leading header block).
    private static func stringBlock(rows: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(UInt64(rows.count), into: &bytes)
        ClickHouseWire.writeString("s", into: &bytes)
        ClickHouseWire.writeString("String", into: &bytes)
        bytes.append(0)
        for row in rows { bytes.append(contentsOf: str(row)) }
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }

    private struct Row: Decodable, Sendable, Equatable { let s: String }

    @Test("header block + two data blocks decode to all rows in order", .timeLimit(.minutes(1)))
    func multiBlockOrder() async throws {
        var reply: [UInt8] = []
        reply.append(contentsOf: Self.stringBlock(rows: []))            // leading header block, 0 rows
        reply.append(contentsOf: Self.stringBlock(rows: ["a", "b"]))    // data block 1
        reply.append(contentsOf: Self.stringBlock(rows: []))            // intermediate empty block
        reply.append(contentsOf: Self.stringBlock(rows: ["c"]))         // data block 2
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT s FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(s: "a"), Row(s: "b"), Row(s: "c")])
    }
}
