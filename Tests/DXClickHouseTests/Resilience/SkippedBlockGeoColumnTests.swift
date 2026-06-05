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

// Geo aliases (Point, Ring, Polygon, ...), Nested, and SimpleAggregateFunction
// are stored under expanded types (Point is Tuple(Float64, Float64)). The data
// block reader expands the column type before walking the body, but the block
// skip path used for Totals/Extremes/Log blocks passed the raw alias straight
// to the width lookup, which only knows the expanded forms. So a query like
// SELECT point_col ... WITH TOTALS decoded its data rows but failed on the
// totals block with "unsupported column type Point". The skip path must apply
// the same expansion as the read path.
@Suite("a Geo column in a skipped Totals block is expanded, not reported unsupported")
struct SkippedBlockGeoColumnTests {

    private static func totalsBlockWithPointColumn() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &bytes)     // Totals packet
        ClickHouseWire.writeString("", into: &bytes)    // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)    // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)    // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)    // row count
        ClickHouseWire.writeString("p", into: &bytes)   // column name
        ClickHouseWire.writeString("Point", into: &bytes) // Geo alias type
        bytes.append(0)                                 // custom serialization flag
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16)) // Tuple(Float64, Float64) row
        ClickHouseWire.writeUVarInt(5, into: &bytes)    // EndOfStream
        return bytes
    }

    @Test("a Totals block carrying a Point column is skipped cleanly", .timeLimit(.minutes(1)))
    func skipsGeoColumnInTotalsBlock() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.totalsBlockWithPointColumn())]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT p FROM t WITH TOTALS")
        let rows = try connection.receiveBlocks { _, _ in }
        server.finished.wait()

        #expect(rows == 0)
    }
}
