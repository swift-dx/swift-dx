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

// Map(String, String) has variable-width values, unlike a fixed-width value
// column: the copy path must walk the flattened value String column entry by
// entry through the same row-by-row length-prefixed reader the key column
// uses. A real SELECT exercises copyMapColumnBody end to end for both
// variable-width sides at once.
@Suite("a Map with String values decodes through the copy path")
struct MapStringValueSelectTests {

    private struct Row: Decodable, Sendable, Equatable { let m: [String: String] }

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
        ClickHouseWire.writeString("m", into: &bytes)
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

    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        ClickHouseWire.writeString(s, into: &out)
        return out
    }

    // One row {"a": "x", "bb": "yy"}: a cumulative offset of 2, the flattened
    // key column ("a", "bb"), then the flattened value column ("x", "yy").
    private static func body() -> [UInt8] {
        var bytes: [UInt8] = uint64LE(2)
        bytes.append(contentsOf: str("a"))
        bytes.append(contentsOf: str("bb"))
        bytes.append(contentsOf: str("x"))
        bytes.append(contentsOf: str("yy"))
        return bytes
    }

    @Test("Map(String, String) decodes into [String: String] via selectAll", .timeLimit(.minutes(1)))
    func decodesThroughCopyPath() async throws {
        var reply = Self.dataBlock(columnType: "Map(String, String)", rowCount: 1, body: Self.body())
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

        #expect(rows == [Row(m: ["a": "x", "bb": "yy"])])
    }
}
