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
import Testing

// A query result's Totals/Extremes/Log blocks are read off the wire and
// SKIPPED, not decoded. For a LowCardinality column the skip reads a
// server-supplied dictionary size and index count. Converting those to Int
// unchecked — or multiplying the index count by the key width — would trap
// and crash the whole client on a value a corrupt or hostile server can
// send. The skip must reject it as malformed.
@Suite("LowCardinality skip rejects an out-of-range index count instead of trapping")
struct LowCardinalitySkipOverflowTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // A Totals packet (type 7) carrying one LowCardinality(UInt8) column
    // whose index count is UInt64.max — the value that overflows when
    // converted to Int.
    private static func totalsBlockWithMalformedLowCardinality() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &bytes)                       // packet type: Totals
        ClickHouseWire.writeString("", into: &bytes)                      // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)                      // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)                      // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)                      // row count
        ClickHouseWire.writeString("lc", into: &bytes)                    // column name
        ClickHouseWire.writeString("LowCardinality(UInt8)", into: &bytes) // column type
        bytes.append(0)                                                   // custom serialization flag
        bytes.append(contentsOf: uint64LE(1))                            // LC keys-version prefix
        bytes.append(contentsOf: uint64LE(0))                            // serialization type (key width 1)
        bytes.append(contentsOf: uint64LE(0))                            // dictionary size
        bytes.append(contentsOf: uint64LE(UInt64.max))                   // index count (overflows Int)
        return bytes
    }

    @Test("a malformed LowCardinality index count in a skipped block is rejected", .timeLimit(.minutes(1)))
    func rejectsOversizedIndexCount() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.totalsBlockWithMalformedLowCardinality())]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT 1")
        var stage = "none"
        do {
            _ = try connection.receiveBlocks { _, _ in }
        } catch {
            if case .protocolError(let parsed, _) = error {
                stage = parsed
            }
        }
        server.finished.wait()

        #expect(stage == "decoder.lowCardinality")
    }
}
