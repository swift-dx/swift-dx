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

// execute() and scalar() translate their timeout into the server-side
// max_execution_time setting so the server, not just the client, bounds
// the work. insert() must do the same: with only a client-side timeout, a
// slow insert keeps running on the server after the client gives up, so
// the caller cannot tell whether the rows landed. Injecting
// max_execution_time makes the timeout bound both sides and the outcome
// predictable. This test drives a real insert against an in-process server
// and asserts the setting is transmitted in the INSERT query.
@Suite("insert bounds the server with max_execution_time, like execute and scalar")
struct InsertServerTimeoutInjectionTests {

    private struct Row: Codable, Sendable {
        let id: UInt8
    }

    // A 0-row sample block whose column matches the encoded row, so schema
    // validation passes and the insert proceeds to completion.
    private static func matchingSampleBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)       // packet type: Data
        ClickHouseWire.writeString("", into: &bytes)       // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)       // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)       // column count
        ClickHouseWire.writeUVarInt(0, into: &bytes)       // row count
        ClickHouseWire.writeString("id", into: &bytes)     // column name (matches Row)
        ClickHouseWire.writeString("UInt8", into: &bytes)  // column type
        bytes.append(0)                                    // custom serialization flag
        return bytes
    }

    @Test("insert transmits the timeout as a server-side max_execution_time setting", .timeLimit(.minutes(1)))
    func insertInjectsMaxExecutionTime() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,                          // INSERT query (carries settings)
                .reply(Self.matchingSampleBlock()),
                .drainRequest,                          // data block + terminator
                .reply([0x05])                          // EndOfStream
            ]
        )

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        _ = try await client.insert(into: "events", rows: [Row(id: 1)], timeout: .seconds(7))
        await client.close()
        server.finished.wait()

        let request = try #require(server.capturedRequests.first)
        let text = String(decoding: request, as: UTF8.self)
        #expect(text.contains("max_execution_time"))
    }
}
