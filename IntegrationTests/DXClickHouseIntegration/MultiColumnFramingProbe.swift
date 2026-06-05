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

// Intra-block framing guard. Each recently-added column shape (LowCardinality
// map keys with their hoisted version, array-valued maps, Array(LowCardinality))
// is read mid-row with plain Int64 sentinels before and after it. If any shape's
// byte-walk consumes the wrong number of bytes, the trailing sentinel decodes to
// a wrong value or the row fails — so exact-value sentinels pin the framing of
// every shape when it is not the only column in the block.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct MultiColumnFramingProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct MixedRow: Decodable, Sendable, Equatable {

        let a: Int64
        let mlc: [String: String]
        let b: Int64
        let marr: [String: [String]]
        let c: Int64
        let alc: [String]
        let d: Int64
    }

    @Test("recently-added column shapes frame correctly between Int64 sentinels", .timeLimit(.minutes(1)))
    func mixedRowFramesCleanly() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            """
            SELECT
              toInt64(100) AS a,
              CAST(map('region', 'eu', 'tier', 'gold') AS Map(LowCardinality(String), String)) AS mlc,
              toInt64(200) AS b,
              map('x', ['a', 'b'], 'y', ['c']) AS marr,
              toInt64(300) AS c,
              CAST(['p', 'q', 'p'] AS Array(LowCardinality(String))) AS alc,
              toInt64(400) AS d
            """,
            as: MixedRow.self
        )
        #expect(rows == [MixedRow(
            a: 100,
            mlc: ["region": "eu", "tier": "gold"],
            b: 200,
            marr: ["x": ["a", "b"], "y": ["c"]],
            c: 300,
            alc: ["p", "q", "p"],
            d: 400
        )])
        await client.close()
    }

    @Test("recently-added shapes frame correctly across multiple rows", .timeLimit(.minutes(1)))
    func mixedMultiRowFramesCleanly() async throws {
        let client = try await Self.makeClient()
        let rows = try await client.selectAll(
            """
            SELECT
              toInt64(number) AS a,
              CAST(map('k', toString(number)) AS Map(LowCardinality(String), String)) AS mlc,
              toInt64(number + 1000) AS b,
              map('v', [toString(number), toString(number + 1)]) AS marr,
              toInt64(number + 2000) AS c,
              CAST([toString(number)] AS Array(LowCardinality(String))) AS alc,
              toInt64(number + 3000) AS d
            FROM numbers(4)
            """,
            as: MixedRow.self
        )
        #expect(rows.count == 4)
        for (offset, row) in rows.enumerated() {
            let number = Int64(offset)
            #expect(row.a == number)
            #expect(row.mlc == ["k": "\(number)"])
            #expect(row.b == number + 1000)
            #expect(row.marr == ["v": ["\(number)", "\(number + 1)"]])
            #expect(row.c == number + 2000)
            #expect(row.alc == ["\(number)"])
            #expect(row.d == number + 3000)
        }
        await client.close()
    }
}
