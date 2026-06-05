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

// ClickHouse geo types are anonymous nested tuples/arrays: Point = Tuple(Float64,
// Float64), Ring = Array(Point), Polygon = Array(Ring). They are a likely spot
// for a decode mis-frame. Each must either decode into the matching wrapper
// (ClickHouseTuple / ClickHouseArrayOfTuple) or fail fast at a clean boundary —
// a follow-up query on the same connection proves the column was consumed to the
// exact byte rather than mis-framed into a hang.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct GeoTypeProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringRow: Codable, Sendable, Equatable { let s: String }
    private struct ProbeRow: Codable, Sendable, Equatable { let x: Int64 }

    private static func decodesOrFailsFastThenRecovers(_ query: String) async throws {
        let client = try await makeClient()
        _ = try? await client.selectAll(query, as: StringRow.self)
        let after = try await client.selectAll("SELECT toInt64(7) AS x", as: ProbeRow.self)
        #expect(after == [ProbeRow(x: 7)])
        await client.close()
    }

    @Test("a Point column decodes into ClickHouseTuple", .timeLimit(.minutes(1)))
    func pointDecode() async throws {
        struct Row: Decodable, Sendable { let v: ClickHouseTuple }
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT (1.5, 2.5)::Point AS v", as: Row.self)
        #expect(rows.count == 1)
        #expect(rows[0].v.elements == [.float64, .float64])
        let trusted = try await client.selectAll("SELECT toString((1.5, 2.5)::Point) AS s", as: StringRow.self)
        #expect(trusted == [StringRow(s: "(1.5,2.5)")])
        await client.close()
    }

    @Test("a Ring column decodes into ClickHouseArrayOfTuple", .timeLimit(.minutes(1)))
    func ringDecode() async throws {
        struct Row: Decodable, Sendable { let v: ClickHouseArrayOfTuple }
        let client = try await Self.makeClient()
        let rows = try await client.selectAll("SELECT [(0., 0.), (1., 0.), (1., 1.)]::Ring AS v", as: Row.self)
        #expect(rows.count == 1)
        #expect(rows[0].v.firstValues.count == 3)
        await client.close()
    }

    @Test("a Polygon column decodes or fails fast and keeps the pool usable", .timeLimit(.minutes(1)))
    func polygonStaysInSync() async throws {
        try await Self.decodesOrFailsFastThenRecovers("SELECT [[(0., 0.), (1., 0.), (1., 1.)]]::Polygon AS s")
    }

    @Test("a MultiPolygon column decodes or fails fast and keeps the pool usable", .timeLimit(.minutes(1)))
    func multiPolygonStaysInSync() async throws {
        try await Self.decodesOrFailsFastThenRecovers("SELECT [[[(0., 0.), (1., 0.), (1., 1.)]]]::MultiPolygon AS s")
    }
}
