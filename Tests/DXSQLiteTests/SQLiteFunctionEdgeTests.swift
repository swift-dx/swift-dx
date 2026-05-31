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

import Foundation
import Testing
import DXSQLite

@Suite("DXSQLite function, aggregate, and collation edge cases")
struct SQLiteFunctionEdgeTests {

    static let prefix = "dxsqlite-fnedge"

    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    struct FunctionEdgeFailure: Error {

        let reason: String
    }

    final class SummingAggregator: SQLiteAggregator {

        private var total: Int64 = 0

        func step(_ arguments: [SQLiteValue]) throws {
            guard case .integer(let value) = arguments[0] else { return }
            total &+= value
        }

        func finalize() throws -> SQLiteValue {
            .integer(total)
        }
    }

    final class ConcatenatingAggregator: SQLiteAggregator {

        private var pieces: [String] = []

        func step(_ arguments: [SQLiteValue]) throws {
            guard case .text(let value) = arguments[0] else { return }
            pieces.append(value)
        }

        func finalize() throws -> SQLiteValue {
            .text(pieces.joined(separator: ","))
        }
    }

    final class CountingAggregator: SQLiteAggregator {

        private var stepCount: Int64 = 0

        func step(_ arguments: [SQLiteValue]) throws {
            stepCount &+= 1
        }

        func finalize() throws -> SQLiteValue {
            if stepCount == 0 {
                return .null
            }
            return .integer(stepCount)
        }
    }

    @Test("scalar functions of arity zero and arity two are callable from a reader and the writer")
    func zeroAndTwoArgumentFunctionsAcrossConnections() async throws {
        let answer = SQLiteFunction(name: "answer", argumentCount: 0) { _ in
            .integer(42)
        }
        let add = SQLiteFunction(name: "add_pair", argumentCount: 2) { arguments in
            guard case .integer(let left) = arguments[0], case .integer(let right) = arguments[1] else {
                return .null
            }
            return .integer(left &+ right)
        }
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2, functions: [answer, add]))

        let writerRows = try await database.write { writer in
            try writer.query("SELECT answer() AS a, add_pair(20, 22) AS s")
        }
        #expect(writerRows.count == 1)
        #expect(try writerRows[0].integer(named: "a") == 42)
        #expect(try writerRows[0].integer(named: "s") == 42)

        let readerRows = try await database.read { reader in
            try reader.query("SELECT answer() AS a, add_pair(100, 23) AS s")
        }
        #expect(readerRows.count == 1)
        #expect(try readerRows[0].integer(named: "a") == 42)
        #expect(try readerRows[0].integer(named: "s") == 123)

        await database.close()
        Self.removeFiles(at: path)
    }

    @Test("a scalar function returning each value kind yields the matching type in a SELECT")
    func scalarFunctionReturnsEveryValueKind() async throws {
        let asInteger = SQLiteFunction(name: "make_integer", argumentCount: 0) { _ in .integer(7) }
        let asReal = SQLiteFunction(name: "make_real", argumentCount: 0) { _ in .real(2.5) }
        let asText = SQLiteFunction(name: "make_text", argumentCount: 0) { _ in .text("order-77") }
        let asBlob = SQLiteFunction(name: "make_blob", argumentCount: 0) { _ in .blob([0x01, 0x02, 0x03]) }
        let asNull = SQLiteFunction(name: "make_null", argumentCount: 0) { _ in .null }
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(
            SQLiteConfiguration(
                location: .file(path: path),
                functions: [asInteger, asReal, asText, asBlob, asNull]
            )
        )

        let rows = try await database.read { reader in
            try reader.query("SELECT make_integer() AS i, make_real() AS r, make_text() AS t, make_blob() AS b, make_null() AS n")
        }
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(try row.value(named: "i").type == .integer)
        #expect(try row.integer(named: "i") == 7)
        #expect(try row.value(named: "r").type == .real)
        #expect(try row.double(named: "r") == 2.5)
        #expect(try row.value(named: "t").type == .text)
        #expect(try row.text(named: "t") == "order-77")
        #expect(try row.value(named: "b").type == .blob)
        #expect(try row.blob(named: "b") == [0x01, 0x02, 0x03])
        #expect(try row.value(named: "n") == .null)
        #expect(try row.value(named: "n").type == .null)

        await database.close()
        Self.removeFiles(at: path)
    }

    @Test("a scalar function whose body throws makes the calling query throw SQLiteError")
    func throwingScalarFunctionPropagatesError() async throws {
        let exploding = SQLiteFunction(name: "explode", argumentCount: 0) { _ in
            throw FunctionEdgeFailure(reason: "deliberate failure")
        }
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), functions: [exploding]))

        await #expect(throws: SQLiteError.self) {
            try await database.read { reader in
                try reader.query("SELECT explode() AS x")
            }
        }

        await database.close()
        Self.removeFiles(at: path)
    }

    @Test("two different custom aggregates in one query keep independent state")
    func twoAggregatesInOneQueryKeepIndependentState() async throws {
        let summing = SQLiteAggregate(name: "edge_sum", argumentCount: 1) { SummingAggregator() }
        let concatenating = SQLiteAggregate(name: "edge_concat", argumentCount: 1) { ConcatenatingAggregator() }
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(
            SQLiteConfiguration(
                location: .file(path: path),
                aggregates: [summing, concatenating]
            )
        )

        try await database.write { writer in
            try writer.execute("CREATE TABLE line_item (quantity INTEGER NOT NULL, sku TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO line_item(quantity, sku) VALUES (?, ?)", parameters: [.integer(2), .text("sku-a")])
            _ = try writer.mutate("INSERT INTO line_item(quantity, sku) VALUES (?, ?)", parameters: [.integer(3), .text("sku-b")])
            _ = try writer.mutate("INSERT INTO line_item(quantity, sku) VALUES (?, ?)", parameters: [.integer(5), .text("sku-c")])
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT edge_sum(quantity) AS total, edge_concat(sku) AS skus FROM line_item")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].integer(named: "total") == 10)
        #expect(try rows[0].text(named: "skus") == "sku-a,sku-b,sku-c")

        await database.close()
        Self.removeFiles(at: path)
    }

    @Test("an aggregate over zero input rows finalizes without a step call")
    func aggregateOverEmptyInputFinalizes() async throws {
        let counting = SQLiteAggregate(name: "edge_count", argumentCount: 1) { CountingAggregator() }
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), aggregates: [counting]))

        try await database.write { writer in
            try writer.execute("CREATE TABLE event (id INTEGER PRIMARY KEY, payload INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO event(id, payload) VALUES (1, 100)", parameters: [])
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT edge_count(payload) AS c FROM event WHERE payload > 1000")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].value(named: "c") == .null)
        #expect(try rows[0].value(named: "c").type == .null)

        await database.close()
        Self.removeFiles(at: path)
    }

    @Test("an aggregate folds correctly over one thousand rows")
    func aggregateFoldsOverOneThousandRows() async throws {
        let summing = SQLiteAggregate(name: "edge_sum_big", argumentCount: 1) { SummingAggregator() }
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), aggregates: [summing]))

        try await database.write { writer in
            try writer.execute("CREATE TABLE measurement (value INTEGER NOT NULL)")
            try writer.transaction { transactional in
                for value in 1...1000 {
                    _ = try transactional.mutate("INSERT INTO measurement(value) VALUES (?)", parameters: [.integer(Int64(value))])
                }
            }
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT edge_sum_big(value) AS total FROM measurement")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].integer(named: "total") == 500500)

        await database.close()
        Self.removeFiles(at: path)
    }

    @Test("a custom collation drives both ORDER BY ordering and WHERE equality")
    func collationDrivesOrderingAndEquality() async throws {
        let caseInsensitive = SQLiteCollation(name: "edge_ci") { left, right in
            left.lowercased().compare(right.lowercased())
        }
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), collations: [caseInsensitive]))

        try await database.write { writer in
            try writer.execute("CREATE TABLE catalog (label TEXT NOT NULL)")
            for label in ["Delta", "alpha", "Charlie", "bravo"] {
                _ = try writer.mutate("INSERT INTO catalog(label) VALUES (?)", parameters: [.text(label)])
            }
        }

        let ordered = try await database.read { reader in
            try reader.query("SELECT label FROM catalog ORDER BY label COLLATE edge_ci, label")
        }
        var labels: [String] = []
        for row in ordered {
            labels.append(try row.text(named: "label"))
        }
        #expect(labels == ["alpha", "bravo", "Charlie", "Delta"])

        let matched = try await database.read { reader in
            try reader.query("SELECT label FROM catalog WHERE label = 'ALPHA' COLLATE edge_ci")
        }
        #expect(matched.count == 1)
        #expect(try matched[0].text(named: "label") == "alpha")

        await database.close()
        Self.removeFiles(at: path)
    }
}
