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

// Array(FixedString(N)) is a hot path for reference lists of fixed-width
// identifiers. The connection copy path lifts the cumulative offsets and the
// flattened inner FixedString column (N bytes per element, no length prefix)
// out of the arena before the decoder rebuilds per-row arrays. A real SELECT
// must route this through copyColumnBody, which direct decoder tests bypass.
@Suite("an Array(FixedString) column decodes through the copy path")
struct ArrayFixedStringSelectTests {

    private struct Row: Decodable, Sendable, Equatable { let refs: [ClickHouseFixedString] }

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
        ClickHouseWire.writeString("refs", into: &bytes)
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

    // Two rows: ["aaaa", "bbbb"] then ["cccc"]. Cumulative offsets 2, 3; the
    // flattened FixedString(4) elements follow with no length prefix.
    private static func body() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: uint64LE(2))
        bytes.append(contentsOf: uint64LE(3))
        bytes.append(contentsOf: Array("aaaa".utf8))
        bytes.append(contentsOf: Array("bbbb".utf8))
        bytes.append(contentsOf: Array("cccc".utf8))
        return bytes
    }

    @Test("Array(FixedString(4)) decodes per-row element arrays", .timeLimit(.minutes(1)))
    func decodesThroughCopyPath() async throws {
        var reply = Self.dataBlock(columnType: "Array(FixedString(4))", rowCount: 2, body: Self.body())
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT refs FROM t", as: Row.self)
        await client.close()

        #expect(rows == [
            Row(refs: [
                ClickHouseFixedString(bytes: Array("aaaa".utf8), length: 4),
                ClickHouseFixedString(bytes: Array("bbbb".utf8), length: 4),
            ]),
            Row(refs: [ClickHouseFixedString(bytes: Array("cccc".utf8), length: 4)]),
        ])
    }
}
