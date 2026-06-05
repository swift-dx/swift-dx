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

// The streaming select reads one result block from the connection per drained
// buffer, so a slow consumer bounds memory to a single block instead of letting
// the server's whole result accumulate in an unbounded continuation buffer. These
// pin that pull behaviour and the connection cleanup when a consumer abandons the
// stream mid-result.
@Suite("streaming select is backpressured and cleans up on abandonment", .serialized)
struct StreamingBackpressureTests {

    // Counts how many rows the decoder materialised, across the worker thread
    // that decodes and the test thread that reads the total after the stream
    // settles. @unchecked Sendable is safe: every access takes the lock.
    private final class DecodeCounter: @unchecked Sendable {

        private let lock = NSLock()
        private var total = 0

        static let shared = DecodeCounter()

        func bump() { lock.lock(); total += 1; lock.unlock() }
        func reset() { lock.lock(); total = 0; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return total }
    }

    private struct CountedRow: Decodable {

        let s: String

        enum CodingKeys: String, CodingKey { case s }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            s = try container.decode(String.self, forKey: .s)
            DecodeCounter.shared.bump()
        }
    }

    private static func str(_ value: String) -> [UInt8] {
        var out: [UInt8] = []
        ClickHouseWire.writeString(value, into: &out)
        return out
    }

    private static func stringBlock(rows: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(UInt64(rows.count), into: &bytes)
        ClickHouseWire.writeString("s", into: &bytes)
        ClickHouseWire.writeString("String", into: &bytes)
        bytes.append(0)
        for row in rows { bytes.append(contentsOf: str(row)) }
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("reading one row decodes only the first block, not the whole result", .timeLimit(.minutes(1)))
    func readsOneBlockOnDemand() async throws {
        DecodeCounter.shared.reset()
        var reply: [UInt8] = []
        reply.append(contentsOf: Self.stringBlock(rows: []))            // header block
        reply.append(contentsOf: Self.stringBlock(rows: ["a", "b"]))   // block 1: 2 rows
        reply.append(contentsOf: Self.stringBlock(rows: ["c", "d"]))   // block 2: 2 rows
        reply.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        var first = ""
        for try await row in client.select("SELECT s FROM t", as: CountedRow.self) {
            first = row.s
            break
        }
        await client.close()

        #expect(first == "a")
        // Eager (unbounded) streaming would have decoded all four rows before the
        // consumer read one; the backpressured stream decodes only block 1.
        #expect(DecodeCounter.shared.value == 2)
    }

    @Test("abandoning a stream mid-result reconnects cleanly for the next query", .timeLimit(.minutes(1)))
    func abandonmentReconnects() async throws {
        var reply: [UInt8] = []
        reply.append(contentsOf: Self.stringBlock(rows: []))
        reply.append(contentsOf: Self.stringBlock(rows: ["a", "b"]))
        reply.append(contentsOf: Self.stringBlock(rows: ["c", "d"]))
        reply.append(contentsOf: Self.endOfStream())

        var followUp: [UInt8] = []
        followUp.append(contentsOf: Self.stringBlock(rows: []))
        followUp.append(contentsOf: Self.stringBlock(rows: ["ok"]))
        followUp.append(contentsOf: Self.endOfStream())

        let server = FakeClickHouseServer()
        server.runScripts(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            scripts: [
                [.drainRequest, .reply(reply)],
                [.drainRequest, .reply(followUp)],
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        for try await _ in client.select("SELECT s FROM t", as: CountedRow.self) {
            break
        }
        // The abandoned stream left blocks unread; the next query must reconnect
        // (second script) rather than read the previous result's stale bytes.
        let rows = try await client.selectAll("SELECT s FROM t2", as: PlainRow.self)
        await client.close()

        #expect(rows == [PlainRow(s: "ok")])
    }

    private struct PlainRow: Decodable, Sendable, Equatable { let s: String }
}
