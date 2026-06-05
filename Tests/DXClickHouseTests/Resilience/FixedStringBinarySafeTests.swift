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

// A ClickHouse FixedString(N) column is N raw bytes per row, not text. It is
// the binary-safe fixed-width type: a hash, a packed identifier, or any byte
// payload that is not valid UTF-8 must survive a round trip byte-for-byte.
// ClickHouseFixedString stores raw [UInt8] (unlike a String column, which is
// decoded through UTF-8), so non-UTF-8 content — embedded NUL, 0xFF, a lone
// continuation byte 0x80 — must not be altered on encode or decode.
@Suite("FixedString carries arbitrary (non-UTF-8) bytes losslessly")
struct FixedStringBinarySafeTests {

    private struct Row: Codable, Sendable, Equatable { let id: ClickHouseFixedString }

    // Deliberately invalid UTF-8: 0xFF (never valid), 0x00 (embedded NUL),
    // 0xFE (never valid), 0x80 (lone continuation byte).
    private static let binary: [UInt8] = [0xFF, 0x00, 0xFE, 0x80]

    @Test("a non-UTF-8 FixedString round-trips through encode then decode")
    func encodeDecodeRoundTrip() throws {
        let rows = [Row(id: ClickHouseFixedString(bytes: Self.binary, length: 4))]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "FixedString(4)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == rows)
        #expect(decoded[0].id.bytes == Self.binary)
    }

    @Test("a non-UTF-8 FixedString decodes byte-for-byte through the copy path", .timeLimit(.minutes(1)))
    func copyPathRoundTrip() async throws {
        var reply: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &reply)
        ClickHouseWire.writeString("", into: &reply)
        ClickHouseWire.writeUVarInt(0, into: &reply)
        ClickHouseWire.writeUVarInt(1, into: &reply)
        ClickHouseWire.writeUVarInt(1, into: &reply)
        ClickHouseWire.writeString("id", into: &reply)
        ClickHouseWire.writeString("FixedString(4)", into: &reply)
        reply.append(0)
        reply.append(contentsOf: Self.binary)
        ClickHouseWire.writeUVarInt(5, into: &reply)

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT id FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(id: ClickHouseFixedString(bytes: Self.binary, length: 4))])
        #expect(rows.first?.id.bytes == Self.binary)
    }
}
