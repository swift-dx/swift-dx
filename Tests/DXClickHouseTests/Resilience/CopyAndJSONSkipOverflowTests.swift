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

// The remaining server-controlled count/length conversions in the block
// skip path (JSON payload length) and the block copy path (the
// string-extracting select's LowCardinality dictionary/index counts) used
// to convert to Int unchecked and trap. Both must reject an out-of-range
// value as malformed instead of crashing the client.
@Suite("block skip and copy reject out-of-range counts instead of trapping")
struct CopyAndJSONSkipOverflowTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func parseStage(_ reply: [UInt8], extractStrings: Bool) throws -> String {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }
        try connection.sendQuery("SELECT 1")
        var stage = "none"
        do {
            if extractStrings {
                _ = try connection.receiveBlocksExtractingStrings { _, _, _, _ in }
            } else {
                _ = try connection.receiveBlocks { _, _ in }
            }
        } catch {
            if case .protocolError(let parsed, _) = error {
                stage = parsed
            }
        }
        server.finished.wait()
        return stage
    }

    @Test("a malformed JSON payload length in a skipped block is rejected", .timeLimit(.minutes(1)))
    func jsonSkipRejectsOversizedLength() throws {
        var reply: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &reply)            // Totals packet
        ClickHouseWire.writeString("", into: &reply)           // table name
        ClickHouseWire.writeUVarInt(0, into: &reply)           // block info
        ClickHouseWire.writeUVarInt(1, into: &reply)           // column count
        ClickHouseWire.writeUVarInt(1, into: &reply)           // row count
        ClickHouseWire.writeString("j", into: &reply)          // column name
        ClickHouseWire.writeString("JSON", into: &reply)       // column type
        reply.append(0)                                        // custom serialization flag
        ClickHouseWire.writeUVarInt(UInt64.max, into: &reply)  // row 0 JSON payload length
        #expect(try Self.parseStage(reply, extractStrings: false) == "decoder.json")
    }

    @Test("a malformed LowCardinality index count in the string-copy path is rejected", .timeLimit(.minutes(1)))
    func copyRejectsOversizedLowCardinalityIndexCount() throws {
        var reply: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &reply)                       // Data packet
        ClickHouseWire.writeString("", into: &reply)                      // table name
        ClickHouseWire.writeUVarInt(0, into: &reply)                      // block info
        ClickHouseWire.writeUVarInt(1, into: &reply)                      // column count
        ClickHouseWire.writeUVarInt(1, into: &reply)                      // row count
        ClickHouseWire.writeString("lc", into: &reply)                    // column name
        ClickHouseWire.writeString("LowCardinality(UInt8)", into: &reply) // column type
        reply.append(0)                                                   // custom serialization flag
        reply.append(contentsOf: Self.uint64LE(1))                       // LC keys version
        reply.append(contentsOf: Self.uint64LE(0))                       // serialization type (key width 1)
        reply.append(contentsOf: Self.uint64LE(0))                       // dictionary size
        reply.append(contentsOf: Self.uint64LE(UInt64.max))              // index count (overflows Int)
        #expect(try Self.parseStage(reply, extractStrings: true) == "decoder.lowCardinality")
    }
}
