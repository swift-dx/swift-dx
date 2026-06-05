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

// LowCardinality carries a per-block dictionary on the wire: each data block
// ships its own dictionary plus indices into it. A large SELECT over a
// LowCardinality column therefore sends several blocks with DIFFERENT
// dictionaries. The decoder must resolve every block's indices against that
// block's own dictionary; leaking a prior block's dictionary forward would
// silently return the wrong category for every row of the later block. The
// two blocks here use disjoint dictionaries and cross-pointing indices so any
// cross-block dictionary bleed yields wrong values, not a crash.
@Suite("multi-block LowCardinality resolves each block against its own dictionary")
struct MultiBlockLowCardinalitySelectTests {

    private struct Row: Decodable, Sendable, Equatable { let code: ClickHouseFixedString }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }

    private static func dataBlock(rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString("code", into: &bytes)
        ClickHouseWire.writeString("LowCardinality(FixedString(4))", into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: body)
        return bytes
    }

    private static func lcBody(dictionary: [String], indices: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: uint64LE(1))                       // LC keys version
        bytes.append(contentsOf: uint64LE(0))                       // serialization type (key width 1)
        bytes.append(contentsOf: uint64LE(UInt64(dictionary.count)))
        for entry in dictionary { bytes.append(contentsOf: Array(entry.utf8)) }
        bytes.append(contentsOf: uint64LE(UInt64(indices.count)))
        bytes.append(contentsOf: indices)
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }

    @Test("two blocks with disjoint dictionaries decode against their own dictionary", .timeLimit(.minutes(1)))
    func perBlockDictionary() async throws {
        var reply: [UInt8] = []
        // Block 1 dict [aaaa, bbbb], indices 0,1 -> aaaa, bbbb
        reply.append(contentsOf: Self.dataBlock(rowCount: 2, body: Self.lcBody(dictionary: ["aaaa", "bbbb"], indices: [0, 1])))
        // Block 2 dict [cccc, dddd], indices 1,0 -> dddd, cccc (would be bbbb,aaaa if dict leaked)
        reply.append(contentsOf: Self.dataBlock(rowCount: 2, body: Self.lcBody(dictionary: ["cccc", "dddd"], indices: [1, 0])))
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT code FROM t", as: Row.self)
        await client.close()

        #expect(rows == [
            Row(code: ClickHouseFixedString(bytes: Array("aaaa".utf8), length: 4)),
            Row(code: ClickHouseFixedString(bytes: Array("bbbb".utf8), length: 4)),
            Row(code: ClickHouseFixedString(bytes: Array("dddd".utf8), length: 4)),
            Row(code: ClickHouseFixedString(bytes: Array("cccc".utf8), length: 4)),
        ])
    }
}
