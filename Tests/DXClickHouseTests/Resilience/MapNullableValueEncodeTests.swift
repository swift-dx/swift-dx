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

// Map(K, Nullable(V)) is now symmetric: a [K: V?] field both decodes and
// encodes. The encoder writes the offsets, the flattened keys, then the
// flattened values as a Nullable(V) column (null mask + values). This
// round-trips [String: String?] and [String: Int64?] through the real wire
// encode/decode, including empty maps and NULL values.
@Suite("Map(K, Nullable(V)) encodes symmetrically and round-trips")
struct MapNullableValueEncodeTests {

    private struct StringRow: Codable, Sendable, Equatable { let m: [String: String?] }
    private struct IntRow: Codable, Sendable, Equatable { let m: [String: Int64?] }

    private static func roundTrip<T: Codable & Sendable>(_ rows: [T]) async throws -> [T] {
        let columns = try ClickHouseRowEncoder().encode(rows)
        var packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseQueryBuilder.revision)
        packet[0] = 1
        var eos: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &eos)
        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(packet + eos)])
        defer { server.stop() }
        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let decoded = try await client.selectAll("SELECT m FROM t", as: T.self)
        await client.close()
        return decoded
    }

    @Test("a [String: String?] batch round-trips with NULL values and empty maps", .timeLimit(.minutes(1)))
    func stringValues() async throws {
        let rows = [
            StringRow(m: ["a": "x", "b": nil]),
            StringRow(m: [:]),
            StringRow(m: ["c": nil, "d": "y"]),
        ]
        let decoded = try await Self.roundTrip(rows)
        #expect(decoded == rows)
    }

    @Test("a [String: Int64?] batch round-trips with NULL values", .timeLimit(.minutes(1)))
    func intValues() async throws {
        let rows = [
            IntRow(m: ["k1": 10, "k2": nil]),
            IntRow(m: ["k3": -5]),
        ]
        let decoded = try await Self.roundTrip(rows)
        #expect(decoded == rows)
    }
}
