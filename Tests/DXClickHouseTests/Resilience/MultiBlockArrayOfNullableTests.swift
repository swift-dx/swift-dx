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

// A large SELECT of an Array(Nullable(String)) column arrives as several data
// blocks. Each block carries its own arrayOfNullable body (offsets, null mask,
// values) and is decoded independently; selectAll concatenates the per-block
// rows. This combines the multi-block accumulation with the nullable-array
// decode to prove the two compose without cross-block state leaking.
@Suite("multi-block Array(Nullable(String)) results concatenate per-block rows")
struct MultiBlockArrayOfNullableTests {

    private struct Row: Decodable, Sendable, Equatable { let v: [String?] }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; ClickHouseWire.writeString(s, into: &out); return out
    }

    private static func block(rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString("v", into: &bytes)
        ClickHouseWire.writeString("Array(Nullable(String))", into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: body)
        return bytes
    }

    @Test("two blocks of Array(Nullable(String)) decode to all rows in order", .timeLimit(.minutes(1)))
    func multiBlockNullableArray() async throws {
        // Block 1: one row ["a", nil]. Block 2: one row [nil, "c"].
        var b1 = Self.uint64LE(2); b1 += [0x00, 0x01]; b1 += Self.str("a") + Self.str("")
        var b2 = Self.uint64LE(2); b2 += [0x01, 0x00]; b2 += Self.str("") + Self.str("c")
        var reply = Self.block(rowCount: 1, body: b1)
        reply += Self.block(rowCount: 1, body: b2)
        var eos: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &eos)
        reply += eos

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT v FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(v: ["a", nil]), Row(v: [nil, "c"])])
    }
}
