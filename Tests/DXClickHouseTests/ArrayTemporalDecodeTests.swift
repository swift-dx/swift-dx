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

// Array(DateTime), Array(Date), and Array(Date32) carry timestamp and date
// sequences, which are everywhere in event and time-series schemas. Each
// element denotes an absolute instant: DateTime is 4-byte epoch seconds,
// Date is 2-byte days since the epoch, Date32 is 4-byte signed days. The
// decoder rejected all three element types, failing the whole select. The
// [Date] decode is strict: it accepts only these temporal element types, not
// a plain numeric array, so a mistyped field is a clear error rather than a
// plausible-but-wrong value.
@Suite("DXClickHouse Array(DateTime) / Array(Date) / Array(Date32) decode")
struct ArrayTemporalDecodeTests {

    struct Row: Codable, Sendable, Equatable { let stamps: [Date] }

    private static let secondsPerDay: TimeInterval = 86_400

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func int32LE(_ value: Int32) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func decode(columnType: String, body: [UInt8]) throws -> [Row] {
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["stamps"],
            columnTypes: [columnType],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        return try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
    }

    @Test("Array(DateTime) decodes each element as epoch seconds")
    func decodesArrayOfDateTime() throws {
        let body = Self.uint64LE(2) + Self.uint32LE(1_000_000_000) + Self.uint32LE(1_700_000_000)
        let rows = try Self.decode(columnType: "Array(DateTime)", body: body)
        #expect(rows == [Row(stamps: [
            Date(timeIntervalSince1970: 1_000_000_000),
            Date(timeIntervalSince1970: 1_700_000_000),
        ])])
    }

    @Test("Array(DateTime('UTC')) with a timezone argument also decodes")
    func decodesArrayOfDateTimeWithZone() throws {
        let body = Self.uint64LE(1) + Self.uint32LE(1_700_000_000)
        let rows = try Self.decode(columnType: "Array(DateTime('UTC'))", body: body)
        #expect(rows == [Row(stamps: [Date(timeIntervalSince1970: 1_700_000_000)])])
    }

    @Test("Array(Date) decodes each element as whole days since the epoch")
    func decodesArrayOfDate() throws {
        let body = Self.uint64LE(2) + Self.uint16LE(20_000) + Self.uint16LE(0)
        let rows = try Self.decode(columnType: "Array(Date)", body: body)
        #expect(rows == [Row(stamps: [
            Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay),
            Date(timeIntervalSince1970: 0),
        ])])
    }

    @Test("Array(Date32) decodes signed days, reaching before the epoch")
    func decodesArrayOfDate32() throws {
        let body = Self.uint64LE(2) + Self.int32LE(20_000) + Self.int32LE(-100)
        let rows = try Self.decode(columnType: "Array(Date32)", body: body)
        #expect(rows == [Row(stamps: [
            Date(timeIntervalSince1970: 20_000 * Self.secondsPerDay),
            Date(timeIntervalSince1970: -100 * Self.secondsPerDay),
        ])])
    }

    @Test("a plain Array(UInt32) is not silently decoded as dates")
    func plainNumericArrayRejected() {
        let body = Self.uint64LE(1) + Self.uint32LE(1_700_000_000)
        #expect(throws: (any Error).self) {
            _ = try Self.decode(columnType: "Array(UInt32)", body: body)
        }
    }
}
