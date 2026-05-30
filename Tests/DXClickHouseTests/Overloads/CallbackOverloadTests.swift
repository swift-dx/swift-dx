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
import DXCore
import Foundation
import Testing

// DXCallback input form for the single-shot operations on
// ClickHouseClient: execute, ping, scalar, select, insert. Each test
// bridges the callback-shaped API into a CheckedContinuation so the
// Swift Testing harness can assert the typed Result outcome.
@Suite(
    "ClickHouseClient DXCallback overload coverage",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseClientCallbackOverloadTests {

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

    struct PointRow: Codable, Sendable, Equatable {
        let v: UInt64
    }

    @Test("execute(_:completion:) delivers .success for a valid SELECT")
    func executeCallbackSuccess() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let outcome: Result<Void, ClickHouseError> = await withCheckedContinuation { continuation in
            client.execute("SELECT 1") { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success: break
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test("ping(completion:) delivers .success against a live broker")
    func pingCallbackSuccess() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let outcome: Result<Void, ClickHouseError> = await withCheckedContinuation { continuation in
            client.ping { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success: break
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test("scalar(_:as:completion:) delivers a typed Result")
    func scalarCallbackSuccess() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let outcome: Result<UInt64, ClickHouseError> = await withCheckedContinuation { continuation in
            client.scalar("SELECT toUInt64(2026)", as: UInt64.self) { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success(let value): #expect(value == 2026)
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test("select(_:as:completion:) delivers the full row set")
    func selectCallbackSuccess() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let outcome: Result<[PointRow], ClickHouseError> = await withCheckedContinuation { continuation in
            client.select("SELECT toUInt64(number) AS v FROM numbers(4)", as: PointRow.self) { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success(let rows): #expect(rows.map(\.v) == [0, 1, 2, 3])
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test("insert(into:rows:completion:) delivers the summary asynchronously")
    func insertCallbackSuccess() async throws {
        let table = Self.uniqueTableName("cb_insert")
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        try await client.execute("DROP TABLE IF EXISTS \(table)")
        try await client.execute("CREATE TABLE \(table) (v UInt64) ENGINE = Memory")
        let outcome: Result<ClickHouseInsertSummary, ClickHouseError> = await withCheckedContinuation { continuation in
            client.insert(into: table, rows: [PointRow(v: 1), PointRow(v: 2)]) { result in
                continuation.resume(returning: result)
            }
        }
        switch outcome {
        case .success(let summary): #expect(summary.rowsSent == 2)
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
        try await client.execute("DROP TABLE \(table)")
    }
}
