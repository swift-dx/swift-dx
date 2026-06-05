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

// scalar() returns a single value. When a query mistakenly returns many
// rows (a forgotten LIMIT or aggregation), the client must reject the
// result at the first multi-row block rather than decode and buffer the
// whole result set only to fail the single-row check afterwards. This
// bounds both the work and the memory spent on the mistake, and the
// connection stays usable for the next query.
@Suite("scalar rejects a multi-row result at the block level")
struct ScalarMultiRowFailFastTests {

    private static func uint8Block(values: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(UInt64(values.count), into: &bytes)
        ClickHouseWire.writeString("result", into: &bytes)
        ClickHouseWire.writeString("UInt8", into: &bytes)
        bytes.append(0) // custom serialization flag
        bytes.append(contentsOf: values)
        return bytes
    }

    private static func uint8BlockThenEndOfStream(values: [UInt8]) -> [UInt8] {
        var bytes = uint8Block(values: values)
        ClickHouseWire.writeUVarInt(5, into: &bytes)
        return bytes
    }

    @Test("a multi-row block is rejected before decoding, and the connection recovers", .timeLimit(.minutes(1)))
    func multiRowScalarFailsFast() async throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [
                .drainRequest,
                .reply(Self.uint8BlockThenEndOfStream(values: [10, 20, 30])),
                .drainRequest,
                .reply(Self.uint8BlockThenEndOfStream(values: [99]))
            ]
        )

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        var threw = false
        var message = ""
        do {
            _ = try await client.scalar("SELECT id FROM events", as: UInt8.self)
        } catch {
            threw = true
            message = "\(error)"
        }
        #expect(threw)
        // The block-level guard names the row count; the post-decode check
        // would instead report the collected row total. Asserting the guard
        // wording proves the result was rejected before being decoded.
        #expect(message.contains("block with 3 rows"))

        let recovered = try await client.scalar("SELECT 1", as: UInt8.self)
        #expect(recovered == 99)

        await client.close()
        server.finished.wait()
    }
}
