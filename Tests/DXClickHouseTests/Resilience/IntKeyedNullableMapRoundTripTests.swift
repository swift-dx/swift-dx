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

// Completes the Map matrix: integer keys combined with nullable values —
// Map(Int64, Nullable(V)) / Map(UInt64, Nullable(V)) decode/encode into
// [Int64: V?] etc. The key-agnostic nullableMap / appendNullableKeyedMap
// helpers handle both the integer key and the NULL value.
@Suite("integer-keyed Map(K, Nullable(V)) columns round-trip")
struct IntKeyedNullableMapRoundTripTests {

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

    private struct Int64StringRow: Codable, Sendable, Equatable { let m: [Int64: String?] }
    private struct Int64Int64Row: Codable, Sendable, Equatable { let m: [Int64: Int64?] }

    @Test("Map(Int64, Nullable(String)) round-trips with NULL values and empty maps", .timeLimit(.minutes(1)))
    func int64KeyNullableString() async throws {
        let rows = [
            Int64StringRow(m: [1: "a", -2: nil, 100: "c"]),
            Int64StringRow(m: [:]),
        ]
        #expect(try await Self.roundTrip(rows) == rows)
    }

    @Test("Map(Int64, Nullable(Int64)) round-trips with NULL values", .timeLimit(.minutes(1)))
    func int64KeyNullableInt64() async throws {
        let rows = [Int64Int64Row(m: [10: 5, 20: nil, -30: -7])]
        #expect(try await Self.roundTrip(rows) == rows)
    }
}
