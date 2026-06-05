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

// A LowCardinality column whose dictionary holds more than 256 distinct
// values serializes its indices at two bytes each (UInt16), not one. Smaller
// dictionaries (the common test case) use one-byte indices, so the wide-index
// path — the connection copy reader and the decoder both deriving the index
// width from the serialization type, then reading little-endian multi-byte
// indices — is exercised only here. An index of 256 is the discriminator:
// read at one byte it collapses to 0 (the wrong dictionary entry) and the
// trailing byte desyncs the stream; read at two bytes it resolves correctly.
@Suite("a LowCardinality dictionary above 256 entries decodes wide indices")
struct LowCardinalityWideIndexTests {

    private struct Row: Decodable, Sendable, Equatable { let lc: String }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // A one-column LowCardinality(String) data block: 257 dictionary entries
    // ("v0".."v256") forcing a two-byte index width, and two rows referencing
    // index 256 and index 0.
    private static func wideIndexBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(2, into: &bytes)
        ClickHouseWire.writeString("lc", into: &bytes)
        ClickHouseWire.writeString("LowCardinality(String)", into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: uint64LE(1))
        bytes.append(contentsOf: uint64LE(1))
        bytes.append(contentsOf: uint64LE(257))
        for value in 0...256 {
            ClickHouseWire.writeString("v\(value)", into: &bytes)
        }
        bytes.append(contentsOf: uint64LE(2))
        bytes.append(contentsOf: uint16LE(256))
        bytes.append(contentsOf: uint16LE(0))
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a 257-entry dictionary resolves a two-byte index correctly", .timeLimit(.minutes(1)))
    func decodesWideIndex() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.wideIndexBlock())]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT lc FROM t", as: Row.self)
        await client.close()

        #expect(rows == [Row(lc: "v256"), Row(lc: "v0")])
    }
}
