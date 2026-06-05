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

// A Dynamic column in a skipped Totals/Extremes/Log block declares its
// member-type count as a server UVarInt. Converting it to Int unchecked
// would trap and crash the whole client on a value exceeding Int. The skip
// must reject it as malformed.
@Suite("Dynamic skip rejects an out-of-range member count instead of trapping")
struct DynamicSkipOverflowTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func totalsBlockWithMalformedDynamic() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &bytes)          // packet type: Totals
        ClickHouseWire.writeString("", into: &bytes)         // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)         // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)         // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)         // row count
        ClickHouseWire.writeString("dyn", into: &bytes)      // column name
        ClickHouseWire.writeString("Dynamic", into: &bytes)  // column type
        bytes.append(0)                                      // custom serialization flag
        bytes.append(contentsOf: uint64LE(0))               // structure version (0, no max-types field)
        ClickHouseWire.writeUVarInt(UInt64.max, into: &bytes) // member count (overflows Int)
        return bytes
    }

    @Test("a malformed Dynamic member count in a skipped block is rejected", .timeLimit(.minutes(1)))
    func rejectsOversizedMemberCount() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.totalsBlockWithMalformedDynamic())]
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

        #expect(stage == "decoder.dynamic")
    }
}
