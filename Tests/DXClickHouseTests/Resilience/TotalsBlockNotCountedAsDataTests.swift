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

// A `SELECT ... WITH TOTALS` returns the data rows in Data packets (type 1)
// followed by a Totals packet (type 7) carrying the one aggregate row, and
// a `WITH EXTREMES` query adds an Extremes packet (type 8). Those metadata
// blocks are not result rows. The drain and string-extracting receive paths
// must skip them exactly as the row-materialising path does, rather than
// counting their rows into the total and copying their column bodies out as
// if they were data — otherwise an aggregation query over-reports its row
// count and leaks the totals/extremes values into the projected results.
@Suite("Totals and Extremes blocks are skipped, not counted as data rows")
struct TotalsBlockNotCountedAsDataTests {

    private static func appendBlock(packetType: UInt64, rows: [String], into bytes: inout [UInt8]) {
        ClickHouseWire.writeUVarInt(packetType, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)             // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)             // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)             // column count
        ClickHouseWire.writeUVarInt(UInt64(rows.count), into: &bytes)
        ClickHouseWire.writeString("s", into: &bytes)            // column name
        ClickHouseWire.writeString("String", into: &bytes)       // column type
        bytes.append(0)                                          // custom serialization flag
        for value in rows {
            ClickHouseWire.writeString(value, into: &bytes)
        }
    }

    private static func dataThenTotalsThenEnd() -> [UInt8] {
        var bytes: [UInt8] = []
        appendBlock(packetType: 1, rows: ["alpha", "beta"], into: &bytes)  // 2 data rows
        appendBlock(packetType: 7, rows: ["totalrow"], into: &bytes)       // 1 totals row
        ClickHouseWire.writeUVarInt(5, into: &bytes)                       // EndOfStream
        return bytes
    }

    @Test("the string-extracting drain returns only the data rows and never the totals value", .timeLimit(.minutes(1)))
    func totalsBlockIsNotExtracted() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.dataThenTotalsThenEnd())]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT s FROM t WITH TOTALS")
        var extracted: [String] = []
        let totalRows = try connection.receiveBlocksExtractingStrings { rowCount, _, _, bodies in
            for body in bodies {
                var offset = 0
                for _ in 0..<rowCount {
                    let length = Int(body[offset])
                    offset += 1
                    extracted.append(String(decoding: body[offset..<offset + length], as: UTF8.self))
                    offset += length
                }
            }
        }
        server.finished.wait()

        #expect(totalRows == 2)
        #expect(extracted == ["alpha", "beta"])
        #expect(!extracted.contains("totalrow"))
    }
}
