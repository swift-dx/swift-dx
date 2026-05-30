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
import NIOCore
import Testing

@Suite("ClickHouse server progress packet")
struct ClickHouseServerProgressPacketTests {

    @Test("modern revision round-trips with all gated stats present")
    func modernRevisionRoundTrip() throws {
        let original = ClickHouseServerProgressPacket(
            rows: 1_000_000,
            bytes: 250_000_000,
            totalRows: 5_000_000,
            totalBytes: .value(1_500_000_000),
            writtenRows: .value(800_000),
            writtenBytes: .value(200_000_000),
            elapsedNanoseconds: .value(4_200_000_000)
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, revision: 54_479)

        let decoded = try ClickHouseServerProgressPacket.decode(from: &buffer, revision: 54_479)
        #expect(decoded == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("legacy revision skips written stats and they decode as unsupported")
    func legacyRevisionDropsWrittenStats() throws {
        let original = ClickHouseServerProgressPacket(
            rows: 100,
            bytes: 4_096,
            totalRows: 100,
            writtenRows: .unsupported,
            writtenBytes: .unsupported
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, revision: 54_400)

        let decoded = try ClickHouseServerProgressPacket.decode(from: &buffer, revision: 54_400)
        #expect(decoded.rows == 100)
        #expect(decoded.totalRows == 100)
        #expect(decoded.writtenRows == .unsupported)
        #expect(decoded.writtenBytes == .unsupported)
    }

    @Test("modern encode and legacy decode produce mismatched bytes that don't silently coerce")
    func revisionMismatchProducesGarbageNotSilentSuccess() throws {
        let original = ClickHouseServerProgressPacket(
            rows: 1, bytes: 2, totalRows: 3, writtenRows: .value(4), writtenBytes: .value(5)
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer, revision: 54_478)

        let leftover = buffer.readableBytes
        let decoded = try ClickHouseServerProgressPacket.decode(from: &buffer, revision: 54_400)
        #expect(decoded.rows == 1)
        #expect(decoded.writtenRows == .unsupported)
        #expect(buffer.readableBytes < leftover)
        #expect(buffer.readableBytes > 0)
    }

}

@Suite("ClickHouse server profile info packet")
struct ClickHouseServerProfileInfoPacketTests {

    @Test("profile info round-trips faithfully")
    func profileInfoRoundTrip() throws {
        let original = ClickHouseServerProfileInfoPacket(
            rows: 12_345,
            blocks: 7,
            bytes: 9_876_543,
            appliedLimit: true,
            rowsBeforeLimit: 100_000,
            calculatedRowsBeforeLimit: false
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer)

        let decoded = try ClickHouseServerProfileInfoPacket.decode(from: &buffer)
        #expect(decoded == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("zero values encode as compact UVarInts")
    func zeroValuesAreCompact() throws {
        let original = ClickHouseServerProfileInfoPacket(
            rows: 0, blocks: 0, bytes: 0,
            appliedLimit: false, rowsBeforeLimit: 0, calculatedRowsBeforeLimit: false
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer)
        #expect(buffer.readableBytes == 6)
    }

}

@Suite("ClickHouse server table columns packet")
struct ClickHouseServerTableColumnsPacketTests {

    @Test("table columns packet round-trips faithfully")
    func tableColumnsRoundTrip() throws {
        let original = ClickHouseServerTableColumnsPacket(
            name: "observability.silver_logs",
            columnsText: "id UUID, timestamp DateTime64(9, 'UTC'), payload String"
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer)

        let decoded = try ClickHouseServerTableColumnsPacket.decode(from: &buffer)
        #expect(decoded == original)
    }

    @Test("packet handles a CH-style multi-column DDL string")
    func realisticDDLPayload() throws {
        let columnsText = "id UUID, ts DateTime64(9, 'UTC'), tags Array(String), labels Map(String, String)"
        let packet = ClickHouseServerTableColumnsPacket(name: "logs", columnsText: columnsText)
        var buffer = ByteBuffer()
        packet.encode(into: &buffer)

        let decoded = try ClickHouseServerTableColumnsPacket.decode(from: &buffer)
        #expect(decoded.columnsText == columnsText)

        let parsed = try ClickHouseTypeNameParser.parse("Array(String)")
        #expect(parsed == .array(of: .string))
    }

}
