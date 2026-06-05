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

// A DateTime64(P) column is a fixed eight-byte tick count whose width the
// copy path derives from the parameterised type name. A real SELECT must
// route it through copyColumnBody and the decoder, not only a direct decode.
@Suite("a DateTime64 column decodes through the connection copy path")
struct DateTime64ColumnSelectTests {

    private struct Row: Decodable, Sendable, Equatable { let ts: ClickHouseDateTime64 }

    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func dataBlock(columnType: String, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("ts", into: &bytes)
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

    @Test("DateTime64(3) ticks decode through selectAll", .timeLimit(.minutes(1)))
    func dateTime64DecodesThroughCopyPath() async throws {
        var reply = Self.dataBlock(columnType: "DateTime64(3)", body: Self.int64LE(1_700_000_000_123))
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT ts FROM t", as: Row.self)
        await client.close()

        #expect(rows.count == 1)
        #expect(rows[0].ts.ticks == 1_700_000_000_123)
        #expect(rows[0].ts.precision == 3)
    }
}
