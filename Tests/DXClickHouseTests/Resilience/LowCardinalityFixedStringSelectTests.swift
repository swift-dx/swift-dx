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

// LowCardinality(FixedString(N)) is a hot path for small fixed-width
// categorical identifiers. The connection copy path
// (copyLowCardinalityColumnBody) reads the dictionary as fixed N-byte
// entries — distinct from the length-prefixed String dictionary — then the
// indices. A real SELECT must route this through copyColumnBody and the
// decoder, which direct decoder round-trip tests bypass.
@Suite("a LowCardinality(FixedString) column decodes through the copy path")
struct LowCardinalityFixedStringSelectTests {

    private struct Row: Decodable, Sendable, Equatable { let code: ClickHouseFixedString }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func dataBlock(columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString("code", into: &bytes)
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

    // Two-entry FixedString(4) dictionary ("aaaa", "bbbb"), one-byte indices
    // pointing rows at entry 0 then entry 1.
    private static func body() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: uint64LE(1))            // LC keys version
        bytes.append(contentsOf: uint64LE(0))            // serialization type (key width 1)
        bytes.append(contentsOf: uint64LE(2))            // dictionary size
        bytes.append(contentsOf: Array("aaaa".utf8))     // dict[0]
        bytes.append(contentsOf: Array("bbbb".utf8))     // dict[1]
        bytes.append(contentsOf: uint64LE(2))            // indices count
        bytes.append(contentsOf: [0x00, 0x01])           // indices
        return bytes
    }

    @Test("LowCardinality(FixedString(4)) decodes its dictionary entries", .timeLimit(.minutes(1)))
    func decodesThroughCopyPath() async throws {
        var reply = Self.dataBlock(columnType: "LowCardinality(FixedString(4))", rowCount: 2, body: Self.body())
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT code FROM t", as: Row.self)
        await client.close()

        #expect(rows == [
            Row(code: ClickHouseFixedString(bytes: Array("aaaa".utf8), length: 4)),
            Row(code: ClickHouseFixedString(bytes: Array("bbbb".utf8), length: 4)),
        ])
    }
}
