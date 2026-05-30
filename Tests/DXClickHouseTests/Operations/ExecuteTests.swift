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
    "ClickHouseClient execute happy paths",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientExecuteTests {

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

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    private static func uniqueTableName(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    @Test("execute(String) runs a simple SELECT successfully")
    func executeSimpleSelect() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("SELECT 1")
    }

    @Test("execute(String) runs a CREATE/DROP DDL pair")
    func executeCreateDrop() async throws {
        let table = Self.uniqueTableName("exec_ddl")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (id UInt64) ENGINE = Memory")
        try await client.execute("DROP TABLE \(table)")
    }

    @Test("execute(String) accepts a per-call timeout override")
    func executeWithTimeoutOverride() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("SELECT 1", timeout: .seconds(5))
    }

    @Test("execute(String, timeout: .zero) disables the local deadline")
    func executeWithZeroTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("SELECT 1", timeout: .zero)
    }

    @Test("execute([UInt8]) round-trips UTF-8 SQL bytes")
    func executeBytesSelect() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute(Array("SELECT 1".utf8))
    }

    @Test("execute([UInt8]) accepts a timeout override")
    func executeBytesWithTimeout() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute(Array("SELECT 1".utf8), timeout: .seconds(5))
    }
}
