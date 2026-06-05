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

// The connection pool's decisive correctness property: a lease grants exclusive
// use of one connection for the closure's lifetime, so two concurrent leases
// never share a connection's request/response stream. With more concurrent tasks
// than connections, the pool must queue the excess and still hand each lease a
// clean connection — a leasing bug that shares a connection would cross-talk the
// scalar results. Each task asks for a distinct, self-identifying value.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct PoolLeaseCrossTalkProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default" }

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

    @Test("more concurrent leases than connections never cross-talk", .timeLimit(.minutes(1)))
    func leasesUnderContentionAreExclusive() async throws {
        let pool = try await Self.makePool(maxConnections: 4)
        let taskCount = 80
        try await withThrowingTaskGroup(of: (Int, UInt64).self) { group in
            for index in 0..<taskCount {
                group.addTask {
                    let value = try await pool.withConnection { connection -> UInt64 in
                        try await connection.sendQuery("SELECT toUInt64(\(index))", queryID: "")
                        return try await connection.receiveScalarUInt64()
                    }
                    return (index, value)
                }
            }
            var seen = 0
            for try await (index, value) in group {
                #expect(value == UInt64(index))
                seen += 1
            }
            #expect(seen == taskCount)
        }
        await pool.close()
    }

    @Test("a single-connection pool serializes concurrent leases correctly", .timeLimit(.minutes(1)))
    func singleConnectionPoolSerializes() async throws {
        let pool = try await Self.makePool(maxConnections: 1)
        try await withThrowingTaskGroup(of: (Int, UInt64).self) { group in
            for index in 0..<40 {
                group.addTask {
                    let value = try await pool.withConnection { connection -> UInt64 in
                        try await connection.sendQuery("SELECT toUInt64(\(index + 1000))", queryID: "")
                        return try await connection.receiveScalarUInt64()
                    }
                    return (index, value)
                }
            }
            for try await (index, value) in group {
                #expect(value == UInt64(index + 1000))
            }
        }
        await pool.close()
    }
}
