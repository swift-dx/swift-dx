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

// LowCardinality(Nullable(String)) is a common ClickHouse column type. Its
// dictionary is serialized as plain inner values with dictionary index 0
// reserved as the NULL placeholder, the same byte layout as
// LowCardinality(String). The decoder reads the dictionary as the base String
// type and resolves each key, treating index 0 as NULL, into a nullable string
// column. This hand-crafted block (index 0 = NULL, index 1 = "x", the single
// row keyed to index 1) must decode to the present value "x" with the whole
// block consumed off the wire so the trailing EndOfStream is read and the next
// request stays in sync.
@Suite("LowCardinality(Nullable(String)) decodes without desyncing")
struct LowCardinalityNullableInnerTests {

    private struct Row: Decodable, Sendable, Equatable { let lc: String }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func dataBlockWithLowCardinalityNullable() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)                                   // packet type: Data
        ClickHouseWire.writeString("", into: &bytes)                                  // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)                                  // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)                                  // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)                                  // row count
        ClickHouseWire.writeString("lc", into: &bytes)                               // column name
        ClickHouseWire.writeString("LowCardinality(Nullable(String))", into: &bytes) // column type
        bytes.append(0)                                                              // custom serialization flag
        bytes.append(contentsOf: uint64LE(1))                                        // LC keys version
        bytes.append(contentsOf: uint64LE(0))                                        // serialization type (key width 1)
        bytes.append(contentsOf: uint64LE(2))                                        // dictionary size (index 0 = NULL)
        ClickHouseWire.writeString("", into: &bytes)                                 // dict[0]: NULL placeholder
        ClickHouseWire.writeString("x", into: &bytes)                                // dict[1]: "x"
        bytes.append(contentsOf: uint64LE(1))                                        // indices count
        bytes.append(1)                                                              // indices[0] -> "x"
        ClickHouseWire.writeUVarInt(5, into: &bytes)                                 // EndOfStream
        return bytes
    }

    @Test("a LowCardinality(Nullable(String)) SELECT decodes the present value and the connection survives", .timeLimit(.minutes(1)))
    func decodesNullableInner() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,
                .reply(Self.dataBlockWithLowCardinalityNullable()),
                .drainRequest,
                .reply([0x04])
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        let rows = try await client.selectAll("SELECT lc FROM t", as: Row.self)
        #expect(rows == [Row(lc: "x")])

        try await client.ping()

        await client.close()
    }
}
