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

// Almost every production timestamp column is typed with a timezone:
// DateTime('UTC'), DateTime64(3, 'America/New_York'). The timezone is display
// metadata — the wire value is the same UTC seconds / sub-second ticks — so
// the decoder matches the DateTime( / DateTime64( prefix and ignores the
// quoted zone (and, for DateTime64, the internal comma between precision and
// zone). This pins that the connection copy path and the precision parser
// handle the timezone-qualified forms, not only the bare ones.
@Suite("timezone-qualified DateTime columns decode through the copy path")
struct TimezoneQualifiedDateTimeSelectTests {

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }

    private static func int64LE(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []; withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }; return out
    }

    private static func dataBlock(columnName: String, columnType: String, rowCount: UInt64, body: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        ClickHouseWire.writeString(columnName, into: &bytes)
        ClickHouseWire.writeString(columnType, into: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: body)
        return bytes
    }

    private static func endOfStream() -> [UInt8] {
        var bytes: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &bytes); return bytes
    }

    private static func runSelect<T: Decodable & Sendable>(reply: [UInt8], as type: T.Type) async throws -> [T] {
        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(reply)])
        defer { server.stop() }
        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let rows = try await client.selectAll("SELECT t FROM x", as: type)
        await client.close()
        return rows
    }

    private struct DateRow: Decodable, Sendable, Equatable { let t: Date }
    private struct DateTime64Row: Decodable, Sendable, Equatable { let t: ClickHouseDateTime64 }
    private struct NullableDateTime64Row: Decodable, Sendable, Equatable { let t: ClickHouseDateTime64? }

    @Test("DateTime('UTC') decodes its UTC seconds, ignoring the zone", .timeLimit(.minutes(1)))
    func timezoneQualifiedDateTime() async throws {
        var body = Self.uint32LE(1000); body.append(contentsOf: Self.uint32LE(2000))
        var reply = Self.dataBlock(columnName: "t", columnType: "DateTime('UTC')", rowCount: 2, body: body)
        reply.append(contentsOf: Self.endOfStream())
        let rows = try await Self.runSelect(reply: reply, as: DateRow.self)
        #expect(rows == [DateRow(t: Date(timeIntervalSince1970: 1000)), DateRow(t: Date(timeIntervalSince1970: 2000))])
    }

    @Test("DateTime64(3, 'America/New_York') parses precision past the comma+zone", .timeLimit(.minutes(1)))
    func timezoneQualifiedDateTime64() async throws {
        var body = Self.int64LE(1000); body.append(contentsOf: Self.int64LE(2000))
        var reply = Self.dataBlock(columnName: "t", columnType: "DateTime64(3, 'America/New_York')", rowCount: 2, body: body)
        reply.append(contentsOf: Self.endOfStream())
        let rows = try await Self.runSelect(reply: reply, as: DateTime64Row.self)
        #expect(rows == [
            DateTime64Row(t: ClickHouseDateTime64(ticks: 1000, precision: 3)),
            DateTime64Row(t: ClickHouseDateTime64(ticks: 2000, precision: 3)),
        ])
    }

    @Test("Nullable(DateTime64(3, 'UTC')) maps the mask and parses inner precision", .timeLimit(.minutes(1)))
    func nullableTimezoneQualifiedDateTime64() async throws {
        var body: [UInt8] = [0x00, 0x01]
        body.append(contentsOf: Self.int64LE(1000)); body.append(contentsOf: Self.int64LE(0))
        var reply = Self.dataBlock(columnName: "t", columnType: "Nullable(DateTime64(3, 'UTC'))", rowCount: 2, body: body)
        reply.append(contentsOf: Self.endOfStream())
        let rows = try await Self.runSelect(reply: reply, as: NullableDateTime64Row.self)
        #expect(rows == [
            NullableDateTime64Row(t: ClickHouseDateTime64(ticks: 1000, precision: 3)),
            NullableDateTime64Row(t: nil),
        ])
    }
}
