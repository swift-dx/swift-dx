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

// Nullable value-wrapper columns (Decimal, FixedString, ...) decode through a
// generic .nullable(mask, inner) wrapper rather than a dedicated nullable case,
// unwrapped at decode time. These are common — nullable amounts and nullable
// fixed-width identifiers — and must round-trip through the connection copy
// path, mapping the null mask to nil and the inner value otherwise.
@Suite("Nullable value-wrapper columns decode through the copy path")
struct NullableValueWrapperSelectTests {

    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
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
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }

    private struct DecimalRow: Decodable, Sendable, Equatable { let amount: ClickHouseDecimal? }
    private struct CodeRow: Decodable, Sendable, Equatable { let code: ClickHouseFixedString? }

    @Test("Nullable(Decimal(10,2)) maps the null mask to nil via selectAll", .timeLimit(.minutes(1)))
    func nullableDecimal() async throws {
        // mask 0,1,0 then unscaled 150, 0, 300 (1.50, NULL, 3.00).
        var body: [UInt8] = [0x00, 0x01, 0x00]
        body.append(contentsOf: Self.int64LE(150)); body.append(contentsOf: Self.int64LE(0)); body.append(contentsOf: Self.int64LE(300))
        var reply = Self.dataBlock(columnName: "amount", columnType: "Nullable(Decimal(10, 2))", rowCount: 3, body: body)
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT amount FROM t", as: DecimalRow.self)
        await client.close()

        #expect(rows == [
            DecimalRow(amount: ClickHouseDecimal(unscaled: 150, precision: 10, scale: 2)),
            DecimalRow(amount: nil),
            DecimalRow(amount: ClickHouseDecimal(unscaled: 300, precision: 10, scale: 2)),
        ])
    }

    @Test("Nullable(FixedString(4)) maps the null mask to nil via selectAll", .timeLimit(.minutes(1)))
    func nullableFixedString() async throws {
        var body: [UInt8] = [0x00, 0x01, 0x00]
        body.append(contentsOf: Array("aaaa".utf8))
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: Array("cccc".utf8))
        var reply = Self.dataBlock(columnName: "code", columnType: "Nullable(FixedString(4))", rowCount: 3, body: body)
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT code FROM t", as: CodeRow.self)
        await client.close()

        #expect(rows == [
            CodeRow(code: ClickHouseFixedString(bytes: Array("aaaa".utf8), length: 4)),
            CodeRow(code: nil),
            CodeRow(code: ClickHouseFixedString(bytes: Array("cccc".utf8), length: 4)),
        ])
    }
}
