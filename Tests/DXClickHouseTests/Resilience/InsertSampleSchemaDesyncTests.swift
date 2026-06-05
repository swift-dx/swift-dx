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

// The INSERT handshake reads the destination table's sample schema before
// sending data. If the server answers with an unexpected packet there, the
// read aborts with its body still on the wire — the same desync hazard the
// result-reading loops have. The insert read path shares the same recovery:
// it closes the connection so the next operation reconnects rather than
// reading the stale packet body as its own response.
@Suite("an unexpected packet during the INSERT sample schema reconnects, not desyncs")
struct InsertSampleSchemaDesyncTests {

    private struct Row: Codable, Sendable { let id: UInt8 }

    @Test("an unexpected sample-schema packet errors the insert, then a ping reconnects", .timeLimit(.minutes(1)))
    func insertReconnectsAfterUnexpectedSamplePacket() async throws {
        let server = FakeClickHouseServer()
        let hello = FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision)
        // Packet type 7 (Totals) is not valid in the sample-schema phase; its
        // three trailing bytes are left unread when the read aborts.
        server.runScripts(
            serverHello: hello,
            scripts: [
                [.drainRequest, .reply([0x07, 0xAA, 0xBB, 0xCC]), .drainRequest, .reply([0x04])],
                [.drainRequest, .reply([0x04])]
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var insertFailed = false
        do {
            _ = try await client.insert(into: "t", rows: [Row(id: 1)])
        } catch {
            insertFailed = true
        }
        #expect(insertFailed)

        try await client.ping()

        await client.close()
    }
}
