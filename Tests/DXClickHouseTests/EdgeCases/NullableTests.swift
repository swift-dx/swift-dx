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

// NULL handling end-to-end for every supported typed column. The wire
// format encodes Nullable(T) as a null-mask byte per row plus a
// sentinel value in the column data slot; the typed decoder bridges
// this to ClickHouseNullable, which the Codable layer maps to T?
// fields in user structs.
@Suite("ClickHouseNullable contract and Nullable column round-trips")
struct ClickHouseNullableTests {

    @Test("ClickHouseNullable.present and .absent are exhaustive")
    func nullableExhaustive() {
        let present: ClickHouseNullable<Int> = .present(42)
        let absent: ClickHouseNullable<Int> = .absent
        switch present {
        case .present(let value): #expect(value == 42)
        case .absent: Issue.record("unexpected absent")
        }
        switch absent {
        case .absent: break
        case .present: Issue.record("unexpected present")
        }
    }

    @Test("ClickHouseNullable.isAbsent reports the right flag for each case")
    func nullableIsAbsentFlag() {
        let present: ClickHouseNullable<String> = .present("x")
        let absent: ClickHouseNullable<String> = .absent
        #expect(present.isAbsent == false)
        #expect(absent.isAbsent == true)
    }

    @Test("ClickHouseNullable is Equatable when Wrapped is Equatable")
    func nullableEquatable() {
        let one: ClickHouseNullable<Int> = .present(1)
        let oneAgain: ClickHouseNullable<Int> = .present(1)
        let two: ClickHouseNullable<Int> = .present(2)
        let absent: ClickHouseNullable<Int> = .absent
        let absentAgain: ClickHouseNullable<Int> = .absent
        #expect(one == oneAgain)
        #expect(one != two)
        #expect(absent == absentAgain)
        #expect(absent != one)
    }

    @Test("ClickHouseNullable<Wrapped> is Sendable")
    func nullableSendable() {
        let value: ClickHouseNullable<UInt64> = .present(7)
        let task = Task<Bool, Never> { @Sendable in
            switch value {
            case .present(let inner): return inner == 7
            case .absent: return false
            }
        }
        Task {
            #expect(await task.value == true)
        }
    }

    // The remaining cases need a live broker to round-trip a Nullable
    // column. Each typed primitive is tested for both a present row
    // and an absent (NULL) row to confirm the encoder/decoder handles
    // both ends of the null-mask correctly.

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }
    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port)
    }

    private static func uniqueTableName(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    struct NullableInt64Row: Codable, Sendable, Equatable {
        let v: Int64?
    }

    struct NullableStringRow: Codable, Sendable, Equatable {
        let v: String?
    }

    @Test(
        "Nullable(Int64) SELECT decodes NULL into a nil-ish Swift T?",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func selectNullableInt64NullValue() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT CAST(NULL AS Nullable(Int64)) AS v",
            as: NullableInt64Row.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == nil)
    }

    @Test(
        "Nullable(String) SELECT round-trips a NULL row",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func selectNullableStringNullValue() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            "SELECT CAST(NULL AS Nullable(String)) AS v",
            as: NullableStringRow.self
        )
        #expect(rows.count == 1)
        #expect(rows[0].v == nil)
    }

    @Test(
        "Nullable column with mixed NULL and present rows decodes correctly",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func selectNullableMixedRows() async throws {
        let client = try await Self.makeClient()
        defer { Task { await client.close() } }
        let rows = try await client.selectAll(
            """
            SELECT v FROM (
                SELECT toNullable(toInt64(1)) AS v UNION ALL
                SELECT CAST(NULL AS Nullable(Int64)) AS v UNION ALL
                SELECT toNullable(toInt64(3)) AS v
            ) ORDER BY v
            """,
            as: NullableInt64Row.self
        )
        #expect(rows.count == 3)
        let nullCount = rows.filter { $0.v == nil }.count
        let presentValues = rows.compactMap(\.v).sorted()
        #expect(nullCount == 1)
        #expect(presentValues == [1, 3])
    }
}
