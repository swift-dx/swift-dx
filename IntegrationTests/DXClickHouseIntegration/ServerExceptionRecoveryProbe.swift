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

// A server-side exception (missing table, syntax error, runtime error) arrives
// as an Exception packet mid-response. The client must surface it as a clean
// typed error AND leave the connection synced: the decisive check is that the
// very next query on the same client returns the correct result. A mishandled
// exception that leaves unread bytes on the wire desyncs every later query.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct ServerExceptionRecoveryProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct IntRow: Decodable, Sendable, Equatable { let v: Int64 }

    private static func expectThrowsThenRecovers(_ badQuery: String, recoverValue: Int64) async throws {
        let client = try await makeClient()
        var threw = false
        do {
            _ = try await client.selectAll(badQuery, as: IntRow.self)
        } catch {
            threw = true
        }
        #expect(threw)
        let after = try await client.selectAll("SELECT toInt64(\(recoverValue)) AS v", as: IntRow.self)
        #expect(after == [IntRow(v: recoverValue)])
        await client.close()
    }

    @Test("a missing-table exception fails cleanly and the connection recovers", .timeLimit(.minutes(1)))
    func missingTableRecovers() async throws {
        try await Self.expectThrowsThenRecovers("SELECT v FROM dx_does_not_exist_xyz", recoverValue: 1)
    }

    @Test("a syntax-error exception fails cleanly and the connection recovers", .timeLimit(.minutes(1)))
    func syntaxErrorRecovers() async throws {
        try await Self.expectThrowsThenRecovers("SELCT toInt64(1) AS v", recoverValue: 2)
    }

    @Test("a runtime exception (division by zero) fails cleanly and recovers", .timeLimit(.minutes(1)))
    func runtimeErrorRecovers() async throws {
        try await Self.expectThrowsThenRecovers("SELECT intDiv(toInt64(1), toInt64(0)) AS v", recoverValue: 3)
    }

    @Test("several server exceptions in a row keep the client usable", .timeLimit(.minutes(1)))
    func repeatedExceptionsRecover() async throws {
        let client = try await Self.makeClient()
        for index in 0..<5 {
            var threw = false
            do {
                _ = try await client.selectAll("SELECT v FROM dx_missing_\(index)", as: IntRow.self)
            } catch {
                threw = true
            }
            #expect(threw)
            let ok = try await client.selectAll("SELECT toInt64(\(index)) AS v", as: IntRow.self)
            #expect(ok == [IntRow(v: Int64(index))])
        }
        await client.close()
    }
}
