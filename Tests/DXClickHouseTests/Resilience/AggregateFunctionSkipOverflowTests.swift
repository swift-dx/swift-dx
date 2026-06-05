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

// An AggregateFunction column in a skipped Totals/Extremes/Log block is
// walked as `rows` fixed-width states; the byte total is rows times the
// per-state width. With a server-supplied row count that product can
// overflow Int and trap, crashing the whole client. The skip must reject
// the overflow as malformed.
@Suite("AggregateFunction skip rejects a row-count width overflow instead of trapping")
struct AggregateFunctionSkipOverflowTests {

    private static func totalsBlockWithHugeRowCount() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &bytes)                                  // packet type: Totals
        ClickHouseWire.writeString("", into: &bytes)                                 // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)                                 // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)                                 // column count
        ClickHouseWire.writeUVarInt(UInt64(Int.max), into: &bytes)                   // row count (overflows when * width)
        ClickHouseWire.writeString("agg", into: &bytes)                              // column name
        ClickHouseWire.writeString("AggregateFunction(sum, UInt64)", into: &bytes)   // column type (8-byte state)
        bytes.append(0)                                                              // custom serialization flag
        return bytes
    }

    @Test("a row count whose state-width product overflows is rejected in the skip path", .timeLimit(.minutes(1)))
    func rejectsRowCountWidthOverflow() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.totalsBlockWithHugeRowCount())]
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

        #expect(stage == "decoder.aggregateFunction")
    }
}
