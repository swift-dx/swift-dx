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

// A Map column reaches the Swift decoder only after the connection copy path
// (copyMapColumnBody) lifts the cumulative entry offsets, the flattened key
// column, and the flattened value column out of the arena. Direct decoder
// round-trip tests build the typed column in memory and skip that copy step,
// so a Map SELECT must be exercised end to end through the real receive path.
@Suite("a Map column decodes through the connection copy path")
struct MapColumnSelectTests {

    private struct Row: Decodable, Sendable, Equatable { let m: [String: UInt8] }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func dataBlock(columnName: String, columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString(columnName, into: &bytes)
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

    // One row holding {"a": 1, "b": 2}: a single cumulative offset of 2, then
    // the flattened key column ("a", "b") and value column (1, 2).
    private static func singleMapRow() -> [UInt8] {
        var body: [UInt8] = uint64LE(2)
        body.append(contentsOf: [0x01, 0x61, 0x01, 0x62])
        body.append(contentsOf: [0x01, 0x02])
        return body
    }

    @Test("Map(String, UInt8) decodes into [String: UInt8] via selectAll", .timeLimit(.minutes(1)))
    func mapDecodesThroughCopyPath() async throws {
        var reply = Self.dataBlock(columnName: "m", columnType: "Map(String, UInt8)", rowCount: 1, body: Self.singleMapRow())
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT m FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(m: ["a": 1, "b": 2])])
    }
}
