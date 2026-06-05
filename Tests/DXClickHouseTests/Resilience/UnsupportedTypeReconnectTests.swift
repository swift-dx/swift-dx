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

// Some column types cannot be sized and drained — a future ClickHouse type
// the client does not know, or a malformed type name. The copy path can only
// abort mid-block on those, leaving the rest of the block unread. The receive
// loop must then close the connection so the next operation transparently
// reconnects, rather than leaving stale result bytes that the next request
// would misread as its own response.
@Suite("an unsupported column type closes the connection so the next op reconnects")
struct UnsupportedTypeReconnectTests {

    private struct Row: Decodable, Sendable { let x: String }

    // One column of an unknown type, with trailing bytes the copy path never
    // reaches: aborting on the unknown type leaves those bytes on the wire.
    private static func unknownTypeBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("x", into: &bytes)
        ClickHouseWire.writeString("FooBar", into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: [0x07, 0x07, 0x07])
        return bytes
    }

    @Test("a SELECT of an unknown type errors, then a ping reconnects and succeeds", .timeLimit(.minutes(1)))
    func unsupportedTypeReconnects() async throws {
        let server = FakeClickHouseServer()
        let hello = FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision)
        server.runScripts(
            serverHello: hello,
            scripts: [
                [.drainRequest, .reply(Self.unknownTypeBlock()), .drainRequest, .reply([0x04])],
                [.drainRequest, .reply([0x04])]
            ]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var selectFailed = false
        do {
            _ = try await client.selectAll("SELECT x", as: Row.self)
        } catch {
            selectFailed = true
        }
        #expect(selectFailed)

        try await client.ping()

        await client.close()
    }
}
