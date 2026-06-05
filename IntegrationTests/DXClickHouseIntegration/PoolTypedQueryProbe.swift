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

// The pool is the concurrency path: the single-connection client serializes, so
// concurrent reads must go through leased connections. Before the leased
// connection exposed a typed read, concurrent callers could only reach the raw
// scalar/drain wire methods and had to decode rows by hand — the typed Codable
// surface the single client offers was unavailable on the path that actually
// needs concurrency. This exercises typed selectAll over leased connections:
// each task decodes a distinct, self-identifying multi-row result, so a leasing
// or decode bug that shared a connection's stream would surface as cross-talk in
// the typed rows.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct PoolTypedQueryProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

    struct NumberRow: Codable, Sendable {

        let n: Int64
    }

    struct LabeledRow: Codable, Sendable {

        let n: Int64
        let label: String
    }

    private static func makePool(maxConnections: Int) async throws -> ClickHouseConnectionPool {
        let configuration = ClickHouseConnectionPool.Configuration(
            endpoints: [ClickHouseEndpoint(host: host, port: port)],
            user: user,
            password: password,
            database: database,
            minConnections: 1,
            maxConnections: maxConnections,
            acquireTimeout: .seconds(20),
            evictionInterval: .seconds(60)
        )
        return try await ClickHouseConnectionPool(configuration: configuration)
    }

    @Test("concurrent typed selectAll over leased connections never cross-talks", .timeLimit(.minutes(1)))
    func typedSelectAllUnderContention() async throws {
        let pool = try await Self.makePool(maxConnections: 4)
        let taskCount = 80
        try await withThrowingTaskGroup(of: (Int, [Int64]).self) { group in
            for index in 0..<taskCount {
                group.addTask {
                    let rows = try await pool.withConnection { connection -> [NumberRow] in
                        try await connection.selectAll(
                            "SELECT toInt64(number + \(index) * 1000) AS n FROM system.numbers LIMIT 5",
                            as: NumberRow.self
                        )
                    }
                    return (index, rows.map(\.n))
                }
            }
            var seen = 0
            for try await (index, values) in group {
                let base = Int64(index) * 1000
                #expect(values == [base, base + 1, base + 2, base + 3, base + 4])
                seen += 1
            }
            #expect(seen == taskCount)
        }
        await pool.close()
    }

    @Test("a single-connection pool serializes concurrent typed selectAll", .timeLimit(.minutes(1)))
    func typedSelectAllSingleConnectionSerializes() async throws {
        let pool = try await Self.makePool(maxConnections: 1)
        try await withThrowingTaskGroup(of: (Int, [Int64]).self) { group in
            for index in 0..<40 {
                group.addTask {
                    let rows = try await pool.withConnection { connection -> [NumberRow] in
                        try await connection.selectAll(
                            "SELECT toInt64(number + \(index + 1000) * 10) AS n FROM system.numbers LIMIT 3",
                            as: NumberRow.self
                        )
                    }
                    return (index, rows.map(\.n))
                }
            }
            for try await (index, values) in group {
                let base = Int64(index + 1000) * 10
                #expect(values == [base, base + 1, base + 2])
            }
        }
        await pool.close()
    }

    @Test("concurrent multi-column typed selectAll decodes each lease independently", .timeLimit(.minutes(1)))
    func multiColumnTypedSelectAll() async throws {
        let pool = try await Self.makePool(maxConnections: 4)
        try await withThrowingTaskGroup(of: (Int, LabeledRow).self) { group in
            for index in 0..<40 {
                group.addTask {
                    let rows = try await pool.withConnection { connection -> [LabeledRow] in
                        try await connection.selectAll(
                            "SELECT toInt64(\(index)) AS n, toString(\(index)) AS label",
                            as: LabeledRow.self
                        )
                    }
                    #expect(rows.count == 1)
                    return (index, rows[0])
                }
            }
            for try await (index, row) in group {
                #expect(row.n == Int64(index))
                #expect(row.label == String(index))
            }
        }
        await pool.close()
    }
}
