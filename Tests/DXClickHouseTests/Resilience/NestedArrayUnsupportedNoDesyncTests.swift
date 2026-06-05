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

// Nested arrays (Array(Array(T))) are common in ClickHouse but not yet a
// decodable element type. The decoder rejects them — but the connection copy
// path recursively drains the full nested body first (outer offsets, inner
// offsets, inner values), so the rejection must land at a clean packet
// boundary and leave the connection usable for the next query. A miscount in
// the recursive drain would desync the stream and break the FOLLOWING query;
// this proves it does not.
@Suite("an unsupported nested Array rejects cleanly without desyncing the connection")
struct NestedArrayUnsupportedNoDesyncTests {

    private struct NestedRow: Decodable, Sendable { let v: [Int64] }
    private struct IntRow: Decodable, Sendable, Equatable { let n: UInt8 }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }

    private static func block(columnName: String, columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
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

    private static func eos() -> [UInt8] {
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }

    // One row holding [[1, 2], [3]]: outer offsets [2]; inner offsets [2, 3];
    // inner Int64 values [1, 2, 3].
    private static func nestedArrayBody() -> [UInt8] {
        uint64LE(2) + uint64LE(2) + uint64LE(3) + int64LE(1) + int64LE(2) + int64LE(3)
    }

    @Test("a rejected nested Array leaves the connection usable for the next query", .timeLimit(.minutes(1)))
    func nestedArrayRejectsWithoutDesync() async throws {
        var reply1 = Self.block(columnName: "v", columnType: "Array(Array(Int64))", rowCount: 1, body: Self.nestedArrayBody())
        reply1.append(contentsOf: Self.eos())
        var reply2 = Self.block(columnName: "n", columnType: "UInt8", rowCount: 1, body: [0x2a])
        reply2.append(contentsOf: Self.eos())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply1), .drainRequest, .reply(reply2)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var rejected = false
        do {
            _ = try await client.selectAll("SELECT v FROM t", as: NestedRow.self)
        } catch {
            rejected = true
        }
        #expect(rejected)

        // The connection must still be at a clean boundary: the next query works.
        let rows = try await client.selectAll("SELECT n FROM t", as: IntRow.self)
        #expect(rows == [IntRow(n: 42)])

        await client.close()
    }
}
