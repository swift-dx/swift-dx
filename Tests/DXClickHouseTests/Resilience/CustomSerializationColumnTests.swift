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

// At protocol revision >= 54454 every column header carries a one-byte
// hasCustomSerialization flag after the type name. ClickHouse sets it to 1
// for sparse columns, whose on-wire body layout (default-run lengths plus
// only the non-default values) is entirely different from the dense layout.
// A client that reads the flag but ignores its value parses the sparse body
// as if it were dense, silently desyncing the stream and yielding garbage
// for that column and every column after it. The header parse must reject a
// custom-serialization column with a typed error instead.
@Suite("a column marked with custom (sparse) serialization is rejected, not misparsed")
struct CustomSerializationColumnTests {

    private static func dataBlockWithCustomSerializationColumn() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)        // packet type: Data
        ClickHouseWire.writeString("", into: &bytes)       // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)       // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)       // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)       // row count
        ClickHouseWire.writeString("x", into: &bytes)      // column name
        ClickHouseWire.writeString("UInt8", into: &bytes)  // column type
        bytes.append(1)                                    // hasCustomSerialization = 1 (sparse)
        bytes.append(42)                                   // one dense UInt8 body byte
        ClickHouseWire.writeUVarInt(5, into: &bytes)       // EndOfStream
        return bytes
    }

    @Test("a custom-serialization column header throws instead of parsing the body as dense", .timeLimit(.minutes(1)))
    func rejectsCustomSerializationColumn() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.dataBlockWithCustomSerializationColumn())]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT x FROM t")
        var stage = "none"
        var rejected = false
        do {
            _ = try connection.receiveBlocks { _, _ in }
        } catch {
            if case .protocolError(let parsed, let message) = error {
                stage = parsed
                rejected = message.contains("custom (sparse) serialization")
            }
        }
        server.finished.wait()

        #expect(stage == "column header")
        #expect(rejected)
    }
}
