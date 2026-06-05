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

// An INSERT first sends the query and reads the server's sample schema,
// which puts the server into "awaiting data" state. If the encoded row
// schema does not match the destination table — a common mistake when a
// Codable struct drifts from the table — validation throws. The client
// must still complete the INSERT with no rows so the server returns to a
// clean boundary; otherwise the connection is left desynced and the next
// query reads stale bytes.
@Suite("a schema-mismatch INSERT leaves the connection usable")
struct InsertSchemaMismatchRecoveryTests {

    private struct Row: Codable, Sendable {
        let id: UInt8
    }

    // A 0-row sample block whose single column name does not match the
    // encoded row, so validation rejects it.
    private static func mismatchedSampleBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)            // packet type: Data
        ClickHouseWire.writeString("", into: &bytes)           // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)           // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)           // column count
        ClickHouseWire.writeUVarInt(0, into: &bytes)           // row count
        ClickHouseWire.writeString("wrong_name", into: &bytes) // column name (mismatch)
        ClickHouseWire.writeString("UInt8", into: &bytes)      // column type
        bytes.append(0)                                        // custom serialization flag
        return bytes
    }

    // A single-UInt8 result block plus EndOfStream, used to satisfy the
    // follow-up scalar that proves the connection is still usable.
    private static func scalarBlockThenEndOfStream(value: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("result", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        bytes.append(value)
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a rejected INSERT recovers the connection so the next query succeeds", .timeLimit(.minutes(1)))
    func rejectedInsertLeavesConnectionUsable() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,                                    // INSERT query
                .reply(Self.mismatchedSampleBlock()),             // sample schema (mismatch)
                .drainRequest,                                    // recovery terminator block
                .reply([0x05]),                                   // EndOfStream
                .drainRequest,                                    // follow-up scalar query
                .reply(Self.scalarBlockThenEndOfStream(value: 42))
            ]
        )

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var insertThrew = false
        do {
            _ = try await client.insert(into: "events", rows: [Row(id: 1)])
        } catch {
            insertThrew = true
        }
        #expect(insertThrew)

        // The connection must be at a clean boundary: this scalar reads the
        // single result row, not stale bytes from the abandoned INSERT.
        let recovered = try await client.scalar("SELECT 1", as: UInt8.self)
        #expect(recovered == 42)

        await client.close()
        server.finished.wait()
    }
}
