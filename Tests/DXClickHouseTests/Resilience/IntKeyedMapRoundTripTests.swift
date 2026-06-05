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

// ClickHouse Map keys are not limited to String — integer-keyed maps
// (Map(Int64, V), Map(UInt64, V)) are common (an id -> value lookup). The map
// decode/encode is key-type agnostic (nativeMap / appendKeyedMap); this
// round-trips the common integer-keyed combinations through the real wire.
@Suite("integer-keyed Map columns round-trip")
struct IntKeyedMapRoundTripTests {

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

    private struct Int64StringRow: Codable, Sendable, Equatable { let m: [Int64: String] }
    private struct UInt64Int64Row: Codable, Sendable, Equatable { let m: [UInt64: Int64] }

    @Test("Map(Int64, String) round-trips, including negative keys and empty maps", .timeLimit(.minutes(1)))
    func int64KeyStringValue() async throws {
        let rows = [
            Int64StringRow(m: [1: "a", -2: "b", 9_999_999_999: "big"]),
            Int64StringRow(m: [:]),
        ]
        let decoded = try await Self.roundTrip(rows)
        #expect(decoded == rows)
    }

    @Test("Map(UInt64, Int64) round-trips", .timeLimit(.minutes(1)))
    func uint64KeyInt64Value() async throws {
        let rows = [
            UInt64Int64Row(m: [100: 5, 200: -7]),
            UInt64Int64Row(m: [18_446_744_073_709_551_615: 0]),
        ]
        let decoded = try await Self.roundTrip(rows)
        #expect(decoded == rows)
    }
}
