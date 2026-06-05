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

// A column's type name is server-supplied and bounded only by the 1 GiB
// string cap. The geo-alias expansion, the typed decoder, and the block
// skip and copy paths all recurse one level per parenthesis, so a hostile
// type such as Array(Array(...)) nested tens of thousands deep overflows the
// thread stack before a single body byte is read. The header parse must
// reject an over-deep type nesting with a typed error instead.
@Suite("a column type nested past the supported depth is rejected, not recursed without bound")
struct DeeplyNestedTypeNameTests {

    private static func zeroRowBlockWithDeeplyNestedColumn(depth: Int) -> [UInt8] {
        let type = String(repeating: "Array(", count: depth) + "Int8" + String(repeating: ")", count: depth)
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)   // Data packet
        ClickHouseWire.writeString("", into: &bytes)  // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)  // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)  // column count
        ClickHouseWire.writeUVarInt(0, into: &bytes)  // row count
        ClickHouseWire.writeString("c", into: &bytes) // column name
        ClickHouseWire.writeString(type, into: &bytes) // deeply nested column type
        bytes.append(0)                               // custom serialization flag
        ClickHouseWire.writeUVarInt(5, into: &bytes)  // EndOfStream
        return bytes
    }

    @Test("a column type nested deeper than the cap is rejected with a typed error", .timeLimit(.minutes(1)))
    func rejectsOverDeepTypeNesting() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.zeroRowBlockWithDeeplyNestedColumn(depth: 100))]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT c FROM t")
        var stage = "none"
        var rejected = false
        do {
            _ = try connection.receiveBlocks { _, _ in }
        } catch {
            if case .protocolError(let parsed, let message) = error {
                stage = parsed
                rejected = message.contains("nesting depth")
            }
        }
        server.finished.wait()

        #expect(stage == "column header")
        #expect(rejected)
    }
}
