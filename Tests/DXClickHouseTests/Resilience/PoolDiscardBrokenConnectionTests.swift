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

// When a leased connection fails mid-operation, the pool must not recycle
// it. A socket broken by an I/O failure, or a protocol stream left
// desynced, would otherwise be returned to the idle stack (or handed
// straight to a parked waiter) and corrupt the next lease. Only a clean
// server-side query rejection leaves the connection reusable; every other
// failure discards it so the pool opens a fresh one.
@Suite("a failed lease discards a broken connection instead of recycling it")
struct PoolDiscardBrokenConnectionTests {

    private enum CleanLeaseError: Error {
        case applicationFailure
    }

    private static func configuration(port: Int) -> ClickHouseConnectionPool.Configuration {
        ClickHouseConnectionPool.Configuration(
            host: "127.0.0.1",
            port: port,
            minConnections: 0,
            maxConnections: 1,
            acquireTimeout: .seconds(2),
            idleConnectionTTL: .seconds(300),
            maxConnectionLifetime: .seconds(3600),
            preflightPing: false,
            evictionInterval: .zero
        )
    }

    @Test("a connection-fatal failure removes the connection from the pool", .timeLimit(.minutes(1)))
    func fatalFailureDiscardsConnection() async throws {
        let server = FakeClickHouseServer()
        // Reply with a lone Data-packet marker, then close: the drain reads
        // the marker, then hits EOF reading the block body and throws
        // unexpectedEOF — a connection-fatal error.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply([0x01])]
        )

        let pool = try await ClickHouseConnectionPool(configuration: Self.configuration(port: server.port))
        defer { Task { await pool.close() } }

        var threw = false
        do {
            try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT 1")
                _ = try await connection.drainBlocks()
            }
        } catch {
            threw = true
        }
        server.finished.wait()

        #expect(threw)
        let stats = await pool.stats()
        #expect(stats.idleConnections == 0)
        #expect(stats.inUseConnections == 0)
        #expect(stats.closedTotal == 1)
    }

    @Test("a clean lease that throws an application error keeps the connection", .timeLimit(.minutes(1)))
    func applicationErrorRetainsConnection() async throws {
        let server = FakeClickHouseServer()
        // Reply with EndOfStream: the query completes cleanly and the
        // connection is at a clean protocol boundary when the body then
        // throws its own, non-connection, error.
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply([0x05])]
        )

        let pool = try await ClickHouseConnectionPool(configuration: Self.configuration(port: server.port))
        defer { Task { await pool.close() } }

        var threw = false
        do {
            try await pool.withConnection { connection in
                try await connection.sendQuery("SELECT 1")
                _ = try await connection.drainBlocks()
                throw CleanLeaseError.applicationFailure
            }
        } catch {
            threw = true
        }
        server.finished.wait()

        #expect(threw)
        let stats = await pool.stats()
        #expect(stats.idleConnections == 1)
        #expect(stats.closedTotal == 0)
    }
}
