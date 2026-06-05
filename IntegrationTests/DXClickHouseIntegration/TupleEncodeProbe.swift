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

// Composite (Tuple / Array(Tuple)) columns insert through the explicit wrapper
// types ClickHouseTuple and ClickHouseArrayOfTuple, the same escape-hatch shape
// ClickHouseDecimal and ClickHouseArray use for columns the schema-less encoder
// cannot infer from a plain Swift type. These pin the supported insert path and
// assert that a nested Swift struct (which the encoder cannot map to a column)
// is rejected with a message that points at the wrapper rather than a generic
// "nested containers are not supported".
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil))
struct TupleEncodeProbe {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")
    }

    private struct StringRow: Codable, Sendable, Equatable { let s: String }

    private static func int64Bytes(_ value: Int64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func uniqueTable(_ prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
    }

    @Test("a ClickHouseTuple inserts into a named Tuple column byte-correct", .timeLimit(.minutes(1)))
    func tupleWrapperEncode() async throws {
        struct Row: Codable, Sendable { let v: ClickHouseTuple }
        let client = try await Self.makeClient()
        let table = Self.uniqueTable("dx_enctuplew")
        try await client.execute("CREATE TABLE \(table) (v Tuple(name String, count Int64)) ENGINE = Memory")
        let tuple = ClickHouseTuple(elements: [.string, .int64], values: [Array("widget".utf8), Self.int64Bytes(42)])
        _ = try await client.insert(into: table, rows: [Row(v: tuple)])
        let back = try await client.selectAll("SELECT toString(v) AS s FROM \(table)", as: StringRow.self)
        #expect(back == [StringRow(s: "('widget',42)")])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("a ClickHouseArrayOfTuple inserts into an Array(Tuple) column byte-correct", .timeLimit(.minutes(1)))
    func arrayOfTupleWrapperEncode() async throws {
        struct Row: Codable, Sendable { let v: ClickHouseArrayOfTuple }
        let client = try await Self.makeClient()
        let table = Self.uniqueTable("dx_encarrtuplew")
        try await client.execute("CREATE TABLE \(table) (v Array(Tuple(name String, count Int64))) ENGINE = Memory")
        let arrayOfTuple = ClickHouseArrayOfTuple(
            firstElement: .string,
            secondElement: .int64,
            firstValues: [Array("a".utf8), Array("b".utf8)],
            secondValues: [Self.int64Bytes(1), Self.int64Bytes(2)]
        )
        _ = try await client.insert(into: table, rows: [Row(v: arrayOfTuple)])
        let back = try await client.selectAll("SELECT toString(v) AS s FROM \(table)", as: StringRow.self)
        #expect(back == [StringRow(s: "[('a',1),('b',2)]")])
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }

    @Test("a nested struct field is rejected with a message pointing at ClickHouseTuple", .timeLimit(.minutes(1)))
    func structRejectionGuidesToWrapper() async throws {
        struct Pair: Codable, Sendable { let name: String; let count: Int64 }
        struct Row: Codable, Sendable { let v: Pair }
        let client = try await Self.makeClient()
        let table = Self.uniqueTable("dx_enctuplestruct")
        try await client.execute("CREATE TABLE \(table) (v Tuple(name String, count Int64)) ENGINE = Memory")
        var message = ""
        do {
            _ = try await client.insert(into: table, rows: [Row(v: Pair(name: "widget", count: 42))])
        } catch {
            message = "\(error)"
        }
        #expect(message.contains("ClickHouseTuple"))
        try await client.execute("DROP TABLE \(table)")
        await client.close()
    }
}
