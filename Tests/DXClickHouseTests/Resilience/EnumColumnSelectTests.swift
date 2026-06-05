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

// An Enum8 column's type name carries quoted names and embedded commas
// ("Enum8('active' = 1, 'inactive' = 2)"). The connection copy path copies
// the one-byte ordinals and the decoder parses the mapping from the type
// string; both must survive a real SELECT, not just a direct decode.
@Suite("an Enum8 column decodes through the connection copy path")
struct EnumColumnSelectTests {

    private struct Row: Decodable, Sendable, Equatable { let status: String }

    private static func dataBlock(columnType: String, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(2, into: &bytes)
        ClickHouseWire.writeString("status", into: &bytes)
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

    @Test("Enum8 decodes its names through selectAll", .timeLimit(.minutes(1)))
    func enumDecodesThroughCopyPath() async throws {
        var reply = Self.dataBlock(columnType: "Enum8('active' = 1, 'inactive' = 2)", body: [0x01, 0x02])
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT status FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(status: "active"), Row(status: "inactive")])
    }
}
