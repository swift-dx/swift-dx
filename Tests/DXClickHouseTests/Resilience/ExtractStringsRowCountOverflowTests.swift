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

// The string-extraction drain copies FixedString column bodies sized as
// width * rowCount. The main copy path guards this product against overflow,
// but the extraction path multiplied raw Int values: a hostile or corrupt
// server declaring a row count near Int.max for a multi-byte FixedString
// column overflowed the product and trapped, crashing the process instead of
// rejecting the block. The extraction path must reject it the same way.
@Suite("the string-extraction drain rejects an overflowing FixedString row count")
struct ExtractStringsRowCountOverflowTests {

    // A Data block declaring a single FixedString(8) column with rowCount =
    // Int.max. width(8) * Int.max overflows; no body bytes are needed because
    // the overflow is detected while sizing the copy.
    private static func overflowFixedStringBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(UInt64(Int.max), into: &bytes)
        ClickHouseWire.writeString("s", into: &bytes)
        ClickHouseWire.writeString("FixedString(8)", into: &bytes)
        bytes.append(0)
        return bytes
    }

    @Test("a FixedString row count that overflows width*rows throws, not traps", .timeLimit(.minutes(1)))
    func overflowThrows() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.overflowFixedStringBlock())]
        )
        defer { server.stop() }

        let connection = try await AsyncClickHouseConnection(
            host: "127.0.0.1", port: server.port, user: "default", password: "", database: "default"
        )
        try await connection.sendQuery("SELECT s FROM t")

        var thrown = false
        do {
            _ = try await connection.extractStringsDrain()
        } catch {
            thrown = true
        }
        #expect(thrown)

        await connection.close()
    }
}
