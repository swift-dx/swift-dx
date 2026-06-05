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

// A ClickHouse Nested column with three or more fields — Nested(sku, quantity,
// price) for line items, Nested(id, name, active, score) for records — is stored
// on the wire as Array(Tuple(...)) with one tuple sub-column per field. The
// two-field Array(Tuple) decode is the common case, but real Nested schemas
// routinely carry three, four, or more fields. Those must decode into [Struct]
// against a real server: one decoded array element per tuple, each tuple field
// mapped to a struct property by name, for any tuple arity.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct ArrayOfTupleMultiFieldDecodeTest {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct LineItem: Decodable, Sendable, Equatable {

        let sku: String
        let quantity: Int64
        let price: Float64
    }

    private struct LineItemRow: Decodable, Sendable, Equatable {

        let v: [LineItem]
    }

    private struct Record: Decodable, Sendable, Equatable {

        let id: Int64
        let name: String
        let active: Bool
        let score: Float64
    }

    private struct RecordRow: Decodable, Sendable, Equatable {

        let v: [Record]
    }

    @Test("a three-field Array(Tuple(...)) column decodes into [Struct]", .timeLimit(.minutes(1)))
    func threeFieldArrayOfTuple() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST([('widget', toInt64(3), toFloat64(1.5)), ('gadget', toInt64(7), toFloat64(2.25))] AS Array(Tuple(sku String, quantity Int64, price Float64))) AS v",
            as: LineItemRow.self
        )
        #expect(rows == [LineItemRow(v: [
            LineItem(sku: "widget", quantity: 3, price: 1.5),
            LineItem(sku: "gadget", quantity: 7, price: 2.25)
        ])])
        await client.close()
    }

    @Test("a four-field Array(Tuple(...)) column decodes into [Struct]", .timeLimit(.minutes(1)))
    func fourFieldArrayOfTuple() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST([(toInt64(1), 'alice', true, toFloat64(9.5)), (toInt64(2), 'bob', false, toFloat64(4.25))] AS Array(Tuple(id Int64, name String, active Bool, score Float64))) AS v",
            as: RecordRow.self
        )
        #expect(rows == [RecordRow(v: [
            Record(id: 1, name: "alice", active: true, score: 9.5),
            Record(id: 2, name: "bob", active: false, score: 4.25)
        ])])
        await client.close()
    }

    @Test("a three-field Array(Tuple(...)) decodes across multiple rows", .timeLimit(.minutes(1)))
    func threeFieldArrayOfTupleMultiRow() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST([('a', toInt64(number), toFloat64(0.5))] AS Array(Tuple(sku String, quantity Int64, price Float64))) AS v FROM numbers(3)",
            as: LineItemRow.self
        )
        #expect(rows == [
            LineItemRow(v: [LineItem(sku: "a", quantity: 0, price: 0.5)]),
            LineItemRow(v: [LineItem(sku: "a", quantity: 1, price: 0.5)]),
            LineItemRow(v: [LineItem(sku: "a", quantity: 2, price: 0.5)])
        ])
        await client.close()
    }

    @Test("an empty three-field Array(Tuple(...)) decodes into an empty array", .timeLimit(.minutes(1)))
    func emptyThreeFieldArrayOfTuple() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            "SELECT CAST([] AS Array(Tuple(sku String, quantity Int64, price Float64))) AS v",
            as: LineItemRow.self
        )
        #expect(rows == [LineItemRow(v: [])])
        await client.close()
    }
}
