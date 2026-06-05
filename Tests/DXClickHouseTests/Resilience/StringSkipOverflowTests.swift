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

// A String column in a skipped Totals/Extremes/Log block is walked one
// length-prefixed value at a time. Converting a per-row length to Int
// unchecked would trap and crash the whole client on a length exceeding
// Int — a single field a corrupt or hostile server can send. The skip must
// reject it as malformed.
@Suite("String skip rejects an out-of-range value length instead of trapping")
struct StringSkipOverflowTests {

    private static func totalsBlockWithMalformedString() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &bytes)          // packet type: Totals
        ClickHouseWire.writeString("", into: &bytes)         // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)         // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)         // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)         // row count
        ClickHouseWire.writeString("s", into: &bytes)        // column name
        ClickHouseWire.writeString("String", into: &bytes)   // column type
        bytes.append(0)                                      // custom serialization flag
        ClickHouseWire.writeUVarInt(UInt64.max, into: &bytes) // row 0 string length (overflows Int)
        return bytes
    }

    @Test("a malformed String value length in a skipped block is rejected", .timeLimit(.minutes(1)))
    func rejectsOversizedStringLength() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.totalsBlockWithMalformedString())]
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

        #expect(stage == "decoder.string")
    }
}
