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

// Array(Array(T)) is now symmetric: a [[T]] field both decodes and encodes.
// The encoder writes the outer offsets, the inner offsets, then the flattened
// innermost elements. This round-trips [[Int64]] and [[String]] through the
// real wire encode/decode, including empty outer and empty inner arrays.
@Suite("Array(Array(T)) encodes symmetrically and round-trips")
struct NestedArrayEncodeTests {

    private struct IntRow: Codable, Sendable, Equatable { let v: [[Int64]] }
    private struct StringRow: Codable, Sendable, Equatable { let v: [[String]] }

    private static func roundTrip<T: Codable & Sendable>(_ rows: [T]) async throws -> [T] {
        let columns = try ClickHouseRowEncoder().encode(rows)
        var packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseQueryBuilder.revision)
        packet[0] = 1
        var eos: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &eos)
        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(packet + eos)])
        defer { server.stop() }
        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let decoded = try await client.selectAll("SELECT v FROM t", as: T.self)
        await client.close()
        return decoded
    }

    @Test("a [[Int64]] batch round-trips including empty outer and empty inner arrays", .timeLimit(.minutes(1)))
    func int64Nested() async throws {
        let rows = [
            IntRow(v: [[1, 2], [3]]),
            IntRow(v: []),
            IntRow(v: [[], [4, 5]]),
        ]
        #expect(try await Self.roundTrip(rows) == rows)
    }

    @Test("a [[String]] batch round-trips", .timeLimit(.minutes(1)))
    func stringNested() async throws {
        let rows = [
            StringRow(v: [["a", "b"], ["c"]]),
            StringRow(v: [[""], []]),
        ]
        #expect(try await Self.roundTrip(rows) == rows)
    }
}
