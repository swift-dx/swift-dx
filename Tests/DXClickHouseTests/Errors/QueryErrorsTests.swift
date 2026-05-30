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

// Sad-path coverage for `ClickHouseError.queryFailed`, which carries a
// fully-decoded `ClickHouseServerException`. The local-only tests pin
// the struct contract (code/name/message/stackTrace/nested) so callers
// can rely on switching on the numeric `code` without a textual blob.
// Live tests against a real broker drive the typed-error path with a
// deliberately invalid SQL statement.
@Suite("ClickHouseError.queryFailed carries decoded server exception")
struct ClickHouseQueryErrorsTests {

    @Test("ClickHouseServerException carries every documented field")
    func serverExceptionCarriesAllFields() {
        let exception = ClickHouseServerException(
            code: 62,
            name: "Syntax",
            message: "Unrecognized token",
            stackTrace: "0x0 fn1\n0x1 fn2",
            nested: [
                ClickHouseServerException(code: 99, name: "Inner", message: "root cause"),
            ]
        )
        #expect(exception.code == 62)
        #expect(exception.name == "Syntax")
        #expect(exception.message == "Unrecognized token")
        #expect(exception.stackTrace == "0x0 fn1\n0x1 fn2")
        #expect(exception.nested.count == 1)
        #expect(exception.nested[0].code == 99)
        #expect(exception.nested[0].message == "root cause")
    }

    @Test("ClickHouseServerException description includes code, name, message")
    func serverExceptionDescription() {
        let exception = ClickHouseServerException(
            code: 81,
            name: "UnknownDatabase",
            message: "Database `nope` does not exist"
        )
        let described = exception.description
        #expect(described.contains("code=81"))
        #expect(described.contains("UnknownDatabase"))
        #expect(described.contains("nope"))
    }

    @Test("ClickHouseServerException nested-chain renders inline")
    func nestedRendersInline() {
        let inner = ClickHouseServerException(code: 999, name: "X", message: "root")
        let outer = ClickHouseServerException(
            code: 100,
            name: "Wrapper",
            message: "outer failure",
            nested: [inner]
        )
        let described = outer.description
        #expect(described.contains("nested="))
        #expect(described.contains("code=999"))
    }

    @Test("queryFailed wraps server exception and surfaces code/name/message/stackTrace")
    func queryFailedWrapsServerException() {
        let exception = ClickHouseServerException(
            code: 47,
            name: "UnknownIdentifier",
            message: "Missing columns: 'nope'",
            stackTrace: "<trace bytes here>"
        )
        let error: ClickHouseError = .queryFailed(serverException: exception)
        switch error {
        case .queryFailed(let captured):
            #expect(captured.code == 47)
            #expect(captured.name == "UnknownIdentifier")
            #expect(captured.message.contains("nope"))
            #expect(captured.stackTrace.contains("trace"))
        default:
            Issue.record("expected .queryFailed")
        }
    }

    @Test("queryFailed is Equatable on the wrapped exception payload")
    func queryFailedEquatable() {
        let lhs: ClickHouseError = .queryFailed(serverException: ClickHouseServerException(code: 1, name: "A", message: "x"))
        let rhs: ClickHouseError = .queryFailed(serverException: ClickHouseServerException(code: 1, name: "A", message: "x"))
        let other: ClickHouseError = .queryFailed(serverException: ClickHouseServerException(code: 2, name: "A", message: "x"))
        #expect(lhs == rhs)
        #expect(lhs != other)
    }

    @Test("ClickHouseServerException default stackTrace is empty string, not optional")
    func defaultStackTraceIsEmptyString() {
        let exception = ClickHouseServerException(code: 1, name: "X", message: "x")
        #expect(exception.stackTrace == "")
        #expect(exception.nested.isEmpty)
    }

    @Test(
        "Live invalid SQL surfaces .queryFailed with non-zero server code",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func liveInvalidSqlSurfacesQueryFailed() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let client = try await ClickHouseClient(host: host, port: port)
        defer { Task { await client.close() } }

        var caught: ClickHouseError?
        do {
            try await client.execute("SELECT this_column_does_not_exist FROM nonexistent_table_xyz_swiftdx")
            Issue.record("expected the query to fail")
        } catch {
            caught = error
        }
        switch caught {
        case .some(.queryFailed(let exception)):
            #expect(exception.code != 0)
            #expect(!exception.name.isEmpty)
            #expect(!exception.message.isEmpty)
        default:
            Issue.record("expected .queryFailed, got \(String(describing: caught))")
        }
    }

    @Test(
        "Live invalid SQL in scalar() surfaces .queryFailed",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func liveScalarOnBadSqlFails() async throws {
        let host = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let client = try await ClickHouseClient(host: host, port: port)
        defer { Task { await client.close() } }

        var caught: ClickHouseError?
        do {
            _ = try await client.scalar("SELECT bad_function_xyz()", as: UInt64.self)
            Issue.record("expected the query to fail")
        } catch {
            caught = error
        }
        switch caught {
        case .some(.queryFailed(let exception)):
            #expect(exception.code != 0)
        default:
            Issue.record("expected .queryFailed, got \(String(describing: caught))")
        }
    }
}
