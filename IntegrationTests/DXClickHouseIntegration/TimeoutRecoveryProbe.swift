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

// A query that exceeds its timeout must fail fast and leave the client usable.
// The trap: a timeout that abandons a half-read response without resetting the
// socket desyncs every later query. Each probe times out a deliberately slow
// query, asserts it fails well before any hang, then proves the very next query
// on the same client returns the correct result.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct TimeoutRecoveryProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct IntRow: Decodable, Sendable, Equatable { let v: Int64 }

    @Test("a slow selectAll times out fast and the client recovers", .timeLimit(.minutes(1)))
    func selectTimeoutRecovers() async throws {
        let client = try await Self.makeClient()
        let start = ContinuousClock.now
        var rejected = false
        do {
            _ = try await client.selectAll(
                "SELECT sum(number) AS v FROM numbers(500000000000)",
                as: IntRow.self,
                timeout: .seconds(1)
            )
        } catch {
            rejected = true
        }
        let elapsed = ContinuousClock.now - start
        #expect(rejected)
        #expect(elapsed < .seconds(15))
        let after = try await client.selectAll("SELECT toInt64(7) AS v", as: IntRow.self)
        #expect(after == [IntRow(v: 7)])
        await client.close()
    }

    @Test("the client survives several timeouts in a row", .timeLimit(.minutes(1)))
    func repeatedTimeoutsRecover() async throws {
        let client = try await Self.makeClient()
        for _ in 0..<3 {
            var rejected = false
            do {
                _ = try await client.selectAll(
                    "SELECT sum(number) AS v FROM numbers(500000000000)",
                    as: IntRow.self,
                    timeout: .seconds(1)
                )
            } catch {
                rejected = true
            }
            #expect(rejected)
        }
        let after = try await client.selectAll("SELECT toInt64(42) AS v", as: IntRow.self)
        #expect(after == [IntRow(v: 42)])
        await client.close()
    }
}
