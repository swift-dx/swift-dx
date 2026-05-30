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

@Suite(
    "AsyncClickHouseConnection smoke",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct AsyncRawClickHouseSmoke {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static func connect() async throws -> AsyncClickHouseConnection {
        try await AsyncClickHouseConnection(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database
        )
    }

    @Test("Async SELECT 1 round-trips via drainBlocks")
    func asyncSelectOneDrain() async throws {
        let connection = try await Self.connect()
        try await connection.sendQuery("SELECT 1")
        let rows = try await connection.drainBlocks()
        #expect(rows == 1)
        await connection.close()
    }

    @Test("Async receiveScalarUInt64 returns expected value")
    func asyncScalar() async throws {
        let connection = try await Self.connect()
        try await connection.sendQuery("SELECT toUInt64(42)")
        let value = try await connection.receiveScalarUInt64()
        #expect(value == 42)
        await connection.close()
    }

    @Test("Async receiveBlocks AsyncThrowingStream yields one block")
    func asyncReceiveBlocksStream() async throws {
        let connection = try await Self.connect()
        try await connection.sendQuery("SELECT toUInt32(123)")
        var observed = 0
        var capturedValue: UInt32 = 0
        for try await body in connection.receiveBlocks() {
            observed += 1
            if body.count >= 4 {
                var storage: UInt32 = 0
                body.withUnsafeBufferPointer { source in
                    withUnsafeMutableBytes(of: &storage) { destination in
                        destination.copyMemory(from: UnsafeRawBufferPointer(start: source.baseAddress, count: 4))
                    }
                }
                capturedValue = UInt32(littleEndian: storage)
            }
        }
        #expect(observed == 1)
        #expect(capturedValue == 123)
        await connection.close()
    }

    @Test("Async two queries on same connection serialise correctly")
    func asyncSequentialQueries() async throws {
        let connection = try await Self.connect()
        try await connection.sendQuery("SELECT toUInt64(7)")
        let first = try await connection.receiveScalarUInt64()
        #expect(first == 7)
        try await connection.sendQuery("SELECT toUInt64(11)")
        let second = try await connection.receiveScalarUInt64()
        #expect(second == 11)
        await connection.close()
    }
}
