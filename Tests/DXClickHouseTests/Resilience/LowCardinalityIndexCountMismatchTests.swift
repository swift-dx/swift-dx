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

// A LowCardinality column carries one dictionary index per row. The block
// header declares the row count; the LC body declares its own index count.
// A valid server keeps them equal. A malformed or hostile server can declare
// fewer indices than rows — the decoded column would then be shorter than the
// block claims, and decoding a later row would index it out of bounds and
// trap. The decoder must reject the mismatch as a typed error instead.
@Suite("a LowCardinality index count below the block row count is rejected")
struct LowCardinalityIndexCountMismatchTests {

    private struct Row: Decodable, Sendable, Equatable { let s: String }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }

    private static func str(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; ClickHouseWire.writeString(s, into: &out); return out
    }

    // Block declares 3 rows, LC body declares only 1 index.
    private static func mismatchedBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(3, into: &bytes)               // block claims 3 rows
        ClickHouseWire.writeString("s", into: &bytes)
        ClickHouseWire.writeString("LowCardinality(String)", into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: uint64LE(1))                      // LC keys version
        bytes.append(contentsOf: uint64LE(0))                      // serialization type (key width 1)
        bytes.append(contentsOf: uint64LE(1))                      // dictionary size
        bytes.append(contentsOf: str("a"))                         // dict[0]
        bytes.append(contentsOf: uint64LE(1))                      // index count: only 1, not 3
        bytes.append(contentsOf: [0x00])                           // single index
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }

    @Test("an LC index count below the row count throws, not traps", .timeLimit(.minutes(1)))
    func mismatchThrows() async throws {
        var reply = Self.mismatchedBlock()
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        var thrown = false
        do {
            _ = try await client.selectAll("SELECT s FROM t", as: Row.self)
        } catch {
            thrown = true
        }
        #expect(thrown)
        await client.close()
    }
}
