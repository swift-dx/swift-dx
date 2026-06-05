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

// SimpleAggregateFunction(func, T) columns (SummingMergeTree /
// AggregatingMergeTree) store their value directly in T's layout. The typed
// decoder learned to strip the wrapper, but the connection's column-copy
// path — which materialises every result column off the wire before the
// decoder runs — did not, so a real SELECT failed at the copy stage with
// "unsupported column type" and the decode path was never reached. This
// drives the full read path end to end through the fake server.
@Suite("SimpleAggregateFunction columns survive the full select read path")
struct SimpleAggregateFunctionSelectTests {

    private struct Row: Decodable, Sendable, Equatable {
        let total: UInt64
    }

    private static func dataBlock(columnName: String, columnType: String, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)          // Data packet
        ClickHouseWire.writeString("", into: &bytes)          // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)          // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)          // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)          // row count
        ClickHouseWire.writeString(columnName, into: &bytes)
        ClickHouseWire.writeString(columnType, into: &bytes)
        bytes.append(0)                                       // no custom serialization
        bytes.append(contentsOf: body)
        return bytes
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a SimpleAggregateFunction(sum, UInt64) column decodes through a real select", .timeLimit(.minutes(1)))
    func decodesThroughCopyPath() async throws {
        var reply = Self.dataBlock(
            columnName: "total",
            columnType: "SimpleAggregateFunction(sum, UInt64)",
            body: Self.uint64LE(42)
        )
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT total FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(total: 42)])
    }
}
