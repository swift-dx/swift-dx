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

// A uvarint that runs the full ten bytes with a tenth byte greater than one
// encodes a value past UInt64.max. The standalone wire reader rejects this as
// an overflow, but the connection's inline fast-path reader used to take the
// terminator branch without the same guard, silently dropping the overflowing
// high bits — so a malformed length or packet-type field from the server
// decoded to a wrong value (0x80×9 + 0x02 collapses to 0) and desynced the
// stream instead of failing cleanly. The inline reader must reject it too.
@Suite("the inline uvarint reader rejects a ten-byte overflow")
struct MalformedVarIntOverflowTests {

    private struct Row: Decodable, Sendable { let value: UInt8 }

    // Nine continuation bytes then a terminator of 2: a well-formed-looking
    // ten-byte uvarint whose value exceeds UInt64.max.
    private static func overflowingVarInt() -> [UInt8] {
        Array(repeating: 0x80, count: 9) + [0x02]
    }

    @Test("a malformed packet-type uvarint fails as an overflow, not a desync", .timeLimit(.minutes(1)))
    func rejectsOverflow() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.overflowingVarInt())]
        )
        defer { server.stop() }

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        defer { Task { await client.close() } }

        var thrownStage = ""
        do {
            _ = try await client.selectAll("SELECT value FROM t", as: Row.self)
            Issue.record("expected the malformed uvarint to throw")
        } catch {
            if case .protocolError(let stage, _) = error { thrownStage = stage }
        }

        #expect(thrownStage == "uvarint")
    }
}
