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

import DXClickHouse
import Foundation
import Testing

// Map and Array(Tuple(...)) element types resolve through one shared type-name
// parser. The decode column builder and the wire reader already handle UUID,
// IPv4, IPv6, and the 128/256-bit integer widths, but the type-name parser
// rejected them — so a Nested(id UUID, ...) or Map(String, UUID) column, both
// everyday production shapes for entity identifiers, failed to decode. These
// confirm the rich element types resolve end to end against a real server.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct TupleRichElementDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static let sampleUUID = "00112233-4455-6677-8899-aabbccddeeff"

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct Entity: Decodable, Sendable, Equatable {

        let id: UUID
        let quantity: Int64
    }

    private struct EntityRow: Decodable, Sendable, Equatable {

        let v: [Entity]
    }

    private struct UUIDMapRow: Decodable, Sendable, Equatable {

        let m: [String: UUID]
    }

    @Test("Array(Tuple(UUID, Int64)) decodes into [Struct] with a UUID field", .timeLimit(.minutes(1)))
    func arrayOfTupleWithUUID() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST([('\(Self.sampleUUID)', toInt64(5)), ('\(Self.sampleUUID)', toInt64(9))] AS Array(Tuple(id UUID, quantity Int64))) AS v",
            as: EntityRow.self
        )
        #expect(rows.count == 1)
        let items = rows[0].v
        #expect(items.count == 2)
        #expect(items.map { $0.id.uuidString.lowercased() } == [Self.sampleUUID, Self.sampleUUID])
        #expect(items.map(\.quantity) == [5, 9])
        await client.close()
    }

    @Test("Map(String, UUID) decodes into a dictionary with UUID values", .timeLimit(.minutes(1)))
    func mapWithUUIDValue() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST(map('primary', '\(Self.sampleUUID)') AS Map(String, UUID)) AS m",
            as: UUIDMapRow.self
        )
        #expect(rows.count == 1)
        let pairs = rows[0].m.map { "\($0.key)=\($0.value.uuidString.lowercased())" }
        #expect(pairs == ["primary=\(Self.sampleUUID)"])
        await client.close()
    }
}
