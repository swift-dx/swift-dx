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

// The AsyncSequence INSERT overload is meant to stream, but it used to
// collect the entire sequence into memory and send it as one block, so a
// large or unbounded source exhausted memory and produced one oversized
// block. It must instead drain the source in bounded batches, sending each
// as its own INSERT, so memory stays bounded by the batch size. With a
// batch size of 2 and three rows, the client performs two INSERTs.
@Suite("the AsyncSequence INSERT streams in bounded batches")
struct AsyncSequenceInsertChunkingTests {

    private struct Row: Codable, Sendable { let id: UInt8 }

    // A 0-row sample block whose single column matches the encoded Row, so
    // the schema validation accepts it and the INSERT proceeds.
    private static func matchingSampleBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeString("id", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0)
        return bytes
    }

    private static func insertSequence() -> [FakeClickHouseServer.ScriptStep] {
        [.drainRequest, .reply(matchingSampleBlock()), .drainRequest, .reply([0x05])]
    }

    @Test("a 3-row stream with batch size 2 performs two batched INSERTs", .timeLimit(.minutes(1)))
    func streamsInBatches() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: Self.insertSequence() + Self.insertSequence()
        )
        defer { server.stop() }

        let source = AsyncStream<Row> { continuation in
            continuation.yield(Row(id: 1))
            continuation.yield(Row(id: 2))
            continuation.yield(Row(id: 3))
            continuation.finish()
        }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let summary = try await client.insert(into: "t", rows: source, batchSize: 2)
        await client.close()

        #expect(summary.rowsSent == 3)
        #expect(summary.blocksSent == 2)
    }
}
