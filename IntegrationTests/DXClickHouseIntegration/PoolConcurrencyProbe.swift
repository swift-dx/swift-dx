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

// The client multiplexes many concurrent operations over a bounded connection
// pool. The decisive correctness property: a query must receive its OWN result
// stream, never another concurrent query's bytes. If two tasks ever share one
// connection's read stream, results cross-talk or the block framing desyncs.
// Each task asks for a distinct, self-identifying value and must get exactly it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct PoolConcurrencyProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct IntRow: Decodable, Sendable, Equatable { let v: Int64 }
    private struct TextRow: Decodable, Sendable, Equatable { let v: String }

    @Test("concurrent scalar selects each receive their own result", .timeLimit(.minutes(1)))
    func concurrentScalarSelects() async throws {
        let client = try await Self.makeClient()
        let count = 60
        try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
            for index in 0..<count {
                group.addTask {
                    let rows = try await client.selectAll("SELECT toInt64(\(index)) AS v", as: IntRow.self)
                    return (index, rows.first?.v ?? -1)
                }
            }
            var seen = 0
            for try await (index, value) in group {
                #expect(value == Int64(index))
                seen += 1
            }
            #expect(seen == count)
        }
        await client.close()
    }

    @Test("concurrent multi-row selects keep their rows un-interleaved", .timeLimit(.minutes(1)))
    func concurrentMultiRowSelects() async throws {
        let client = try await Self.makeClient()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<40 {
                group.addTask {
                    // Each task's rows are a distinct arithmetic series keyed by index;
                    // an interleave from another task's connection would break the sum.
                    let rows = try await client.selectAll(
                        "SELECT toInt64(number * \(index + 1)) AS v FROM numbers(50)",
                        as: IntRow.self
                    )
                    let expected = (0..<50).map { Int64($0 * (index + 1)) }
                    return rows.map(\.v) == expected
                }
            }
            var allMatched = true
            for try await matched in group where !matched { allMatched = false }
            #expect(allMatched)
        }
        await client.close()
    }

    @Test("concurrent streaming selects never cross-talk (correct value or clean error)", .timeLimit(.minutes(1)))
    func concurrentStreamingNoCrossTalk() async throws {
        let client = try await Self.makeClient()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    var values: [Int64] = []
                    do {
                        for try await row in client.select("SELECT toInt64(\(index)) AS v", as: IntRow.self) {
                            values.append(row.v)
                        }
                    } catch {
                        // A clean rejection while another stream holds the single
                        // connection is acceptable; a wrong value is not.
                        return
                    }
                    #expect(values == [Int64(index)])
                }
            }
        }
        // The single connection must still be usable after the concurrent storm:
        // a stuck single-flight flag or a desync would break this follow-up.
        let after = try await client.selectAll("SELECT toInt64(7) AS v", as: IntRow.self)
        #expect(after == [IntRow(v: 7)])
        await client.close()
    }

    @Test("sequential streaming selects each return their own rows", .timeLimit(.minutes(1)))
    func sequentialStreamingReleasesTheConnection() async throws {
        let client = try await Self.makeClient()
        for index in 0..<40 {
            var values: [Int64] = []
            for try await row in client.select("SELECT toInt64(\(index * 7)) AS v", as: IntRow.self) {
                values.append(row.v)
            }
            #expect(values == [Int64(index * 7)])
        }
        await client.close()
    }

    @Test("concurrent string selects do not cross-talk across pooled connections", .timeLimit(.minutes(1)))
    func concurrentStringSelects() async throws {
        let client = try await Self.makeClient()
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<40 {
                group.addTask {
                    let rows = try await client.selectAll("SELECT concat('row_', toString(\(index))) AS v", as: TextRow.self)
                    return (index, rows.first?.v ?? "")
                }
            }
            for try await (index, value) in group {
                #expect(value == "row_\(index)")
            }
        }
        await client.close()
    }

    private struct InsertRow: Encodable, Sendable { let v: Int64 }

    @Test("an insert while a result stream is mid-flight is rejected, not interleaved", .timeLimit(.minutes(1)))
    func insertDuringStreamRejected() async throws {
        let client = try await Self.makeClient()
        let table = "dx_insstream_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try await client.execute("CREATE TABLE \(table) (v Int64) ENGINE = Memory")
        var message = ""
        do {
            // Open a many-block stream (one row per block, so almost nothing is
            // buffered) and pull one row, leaving it mid-result so it still holds
            // the single connection. An insert issued now must not interleave its
            // INSERT frame onto the shared wire and desync; it must be rejected at
            // a clean boundary.
            var iterator = client.select("SELECT toInt64(number) AS v FROM numbers(500) SETTINGS max_block_size = 1", as: IntRow.self).makeAsyncIterator()
            _ = try await iterator.next()
            do {
                _ = try await client.insert(into: table, rows: [InsertRow(v: 1)])
            } catch {
                message = "\(error)"
            }
        }
        #expect(message.contains("concurrentQuery"))
        await client.close()
    }
}
