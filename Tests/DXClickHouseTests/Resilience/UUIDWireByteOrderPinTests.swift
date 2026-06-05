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

// ClickHouse stores a UUID as two little-endian 8-byte halves, so the wire
// bytes are each half of the text-form bytes reversed. Round-trip tests prove
// encode and decode are mutual inverses but cannot catch a swap whose
// DIRECTION is wrong in both — that would still round-trip yet be incompatible
// with a real ClickHouse server. This pins the absolute byte layout against a
// hand-derived ClickHouse example, independent of the production swap code.
//
// UUID 00112233-4455-6677-8899-aabbccddeeff has text-form bytes
// 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff; ClickHouse transmits the
// two halves byte-reversed: 77 66 55 44 33 22 11 00  ff ee dd cc bb aa 99 88.
@Suite("UUID wire byte order matches ClickHouse's two little-endian halves")
struct UUIDWireByteOrderPinTests {

    private struct Row: Codable, Sendable, Equatable { let id: UUID }

    private static let uuid = UUID(uuid: (
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
    ))

    private static let wire: [UInt8] = [
        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
        0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88
    ]

    @Test("a scalar UUID encodes to the exact ClickHouse wire bytes")
    func encodesToClickHouseWire() throws {
        let columns = try ClickHouseRowEncoder().encode([Row(id: Self.uuid)])
        #expect(columns[0].column.typeName == "UUID")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(
            columns: columns,
            revision: ClickHouseBlockWriter.revisionWithCustomSerialization
        )
        #expect(Array(packet.suffix(16)) == Self.wire)
    }

    @Test("the exact ClickHouse wire bytes decode to the expected UUID", .timeLimit(.minutes(1)))
    func decodesFromClickHouseWire() async throws {
        var reply: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &reply)
        ClickHouseWire.writeString("", into: &reply)
        ClickHouseWire.writeUVarInt(0, into: &reply)
        ClickHouseWire.writeUVarInt(1, into: &reply)
        ClickHouseWire.writeUVarInt(1, into: &reply)
        ClickHouseWire.writeString("id", into: &reply)
        ClickHouseWire.writeString("UUID", into: &reply)
        reply.append(0)
        reply.append(contentsOf: Self.wire)
        ClickHouseWire.writeUVarInt(5, into: &reply)

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT id FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(id: Self.uuid)])
    }
}
