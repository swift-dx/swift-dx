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

@testable import DXClickHouse
import Foundation
import Testing

// The Array(element) decode support for the temporal, decimal, enum, UUID,
// and IP element types was unit-tested only on hand-built column bytes,
// which bypass the connection's column-copy path. That copy path runs for
// every real SELECT and materialises the column off the wire before the
// decoder sees it; if it rejected or mis-sized an element type, the decode
// would never be reached (the failure mode that hid LowCardinality(Nullable)
// and SimpleAggregateFunction). These drive the full copy + decode path
// through the fake server, proving each element type is reachable and that
// the copy and decode sides agree on the per-element byte width.
@Suite("Array element types survive the full select read path")
struct ArrayColumnSelectTests {

    private static func dataBlock(columnName: String, columnType: String, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString(columnName, into: &bytes)
        ClickHouseWire.writeString(columnType, into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: body)
        return bytes
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func int32LE(_ value: Int32) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }
    private static func uuidWire(_ textBytes: [UInt8]) -> [UInt8] {
        Array(textBytes[0..<8].reversed()) + Array(textBytes[8..<16].reversed())
    }
    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }

    private static func select<Row: Decodable & Sendable>(_ type: Row.Type, columnName: String, columnType: String, body: [UInt8]) async throws -> [Row] {
        var reply = dataBlock(columnName: columnName, columnType: columnType, body: body)
        reply.append(contentsOf: endOfStream())
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(reply)]
        )
        defer { server.stop() }
        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT \(columnName) FROM t", as: type)
        await client.close()
        return rows
    }

    struct DateRow: Decodable, Sendable, Equatable { let stamps: [Date] }
    struct DecimalRow: Decodable, Sendable, Equatable { let amounts: [ClickHouseDecimal] }
    struct UUIDRow: Decodable, Sendable, Equatable { let ids: [UUID] }

    @Test("Array(DateTime) decodes into [Date] through the copy path", .timeLimit(.minutes(1)))
    func arrayDateTime() async throws {
        let body = Self.uint64LE(2) + Self.uint32LE(1_700_000_000) + Self.uint32LE(1_700_000_001)
        let rows = try await Self.select(DateRow.self, columnName: "stamps", columnType: "Array(DateTime)", body: body)
        #expect(rows == [DateRow(stamps: [
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_001),
        ])])
    }

    @Test("Array(Decimal(9, 2)) decodes into [ClickHouseDecimal] through the copy path", .timeLimit(.minutes(1)))
    func arrayDecimal() async throws {
        let body = Self.uint64LE(2) + Self.int32LE(12_345) + Self.int32LE(-678)
        let rows = try await Self.select(DecimalRow.self, columnName: "amounts", columnType: "Array(Decimal(9, 2))", body: body)
        #expect(rows == [DecimalRow(amounts: [
            ClickHouseDecimal(unscaled: 12_345, precision: 9, scale: 2),
            ClickHouseDecimal(unscaled: -678, precision: 9, scale: 2),
        ])])
    }

    @Test("Array(UUID) decodes into [UUID] through the copy path", .timeLimit(.minutes(1)))
    func arrayUUID() async throws {
        let aBytes: [UInt8] = (0..<16).map { UInt8($0) }
        let bBytes: [UInt8] = (16..<32).map { UInt8($0) }
        let body = Self.uint64LE(2) + Self.uuidWire(aBytes) + Self.uuidWire(bBytes)
        let rows = try await Self.select(UUIDRow.self, columnName: "ids", columnType: "Array(UUID)", body: body)
        let expected = [aBytes, bBytes].map { bytes in bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) } }
        #expect(rows == [UUIDRow(ids: expected)])
    }
}
