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

// Map(K, Nullable(V)) is a common shape (a map whose values may be NULL) that
// is not yet a decodable column. The decoder rejects it — but the connection
// copy path recursively drains the full body first (offsets, flattened keys,
// then the flattened Nullable(V) value column as a null mask + values), so the
// rejection must land at a clean packet boundary and leave the connection
// usable for the next query. A miscount in the recursive value drain would
// desync the following query; this proves it does not.
@Suite("an unsupported Map(K, Nullable(V)) rejects cleanly without desyncing")
struct NullableMapValueNoDesyncTests {

    private struct MapRow: Decodable, Sendable { let m: [String: String] }
    private struct IntRow: Decodable, Sendable, Equatable { let n: UInt8 }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; ClickHouseWire.writeString(s, into: &out); return out
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

    // One row {a: "x", b: NULL}: offsets [2]; keys "a","b"; values as
    // Nullable(String) = mask [0,1] then "x","" (placeholder for the NULL).
    private static func mapBody() -> [UInt8] {
        var bytes = uint64LE(2)
        bytes += str("a") + str("b")
        bytes += [0x00, 0x01]
        bytes += str("x") + str("")
        return bytes
    }

    @Test("a rejected Map(K, Nullable(V)) leaves the connection usable", .timeLimit(.minutes(1)))
    func nullableMapRejectsWithoutDesync() async throws {
        var reply1 = Self.block(columnName: "m", columnType: "Map(String, Nullable(String))", rowCount: 1, body: Self.mapBody())
        reply1 += Self.eos()
        var reply2 = Self.block(columnName: "n", columnType: "UInt8", rowCount: 1, body: [0x2a])
        reply2 += Self.eos()

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply1), .drainRequest, .reply(reply2)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var rejected = false
        do {
            _ = try await client.selectAll("SELECT m FROM t", as: MapRow.self)
        } catch {
            rejected = true
        }
        #expect(rejected)

        let rows = try await client.selectAll("SELECT n FROM t", as: IntRow.self)
        #expect(rows == [IntRow(n: 42)])

        await client.close()
    }
}
