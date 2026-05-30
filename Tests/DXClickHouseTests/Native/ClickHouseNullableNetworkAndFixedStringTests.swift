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
import NIOCore
import Testing

@Suite("Nullable(IPv4)/Nullable(IPv6)/Nullable(FixedString) — INSERT/SELECT round-trip")
struct ClickHouseNullableNetworkAndFixedStringTests {

    // MARK: - Nullable(IPv4) — INSERT

    @Test("INSERT .nullableIPv4 builds a Nullable column with UInt32 inner and the supplied null mask")
    func insertNullableIPv4() throws {
        let optionals: [UInt32?] = [0x7F00_0001, nil, 0xC633_6408]
        let column = try ClickHouseClient.toInternalColumn(.nullableIPv4(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .ipv4))
        #expect(typed.nullMask == [false, true, false])
        let inner = try #require(typed.inner as? ClickHouseFixedWidthIntegerColumn<UInt32>)
        #expect(inner.values[0] == 0x7F00_0001)
        #expect(inner.values[2] == 0xC633_6408)
    }

    @Test("INSERT all-nil .nullableIPv4 column produces a column with rowCount matching the input")
    func insertAllNilIPv4() throws {
        let optionals: [UInt32?] = [nil, nil, nil, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableIPv4(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.rowCount == 4)
        #expect(typed.nullMask.allSatisfy { $0 })
    }

    // MARK: - Nullable(IPv6) — INSERT

    @Test("INSERT .nullableIPv6 builds a Nullable column with FixedString(16) inner")
    func insertNullableIPv6() throws {
        let loopback = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let optionals: [Data?] = [loopback, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableIPv6(optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .ipv6))
        #expect(typed.nullMask == [false, true])
        let inner = try #require(typed.inner as? ClickHouseFixedStringColumn)
        #expect(inner.length == 16)
        #expect(inner.values[0] == loopback)
    }

    @Test("INSERT .nullableIPv6 throws when an element has the wrong byte length")
    func insertNullableIPv6WrongLengthThrows() {
        let bad: [Data?] = [Data(repeating: 0, count: 8)]  // 8 bytes, not 16
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.toInternalColumn(.nullableIPv6(bad.map(ClickHouseNullable.init)))
        }
    }

    // MARK: - Nullable(FixedString) — INSERT

    @Test("INSERT .nullableFixedString(length: 4) builds a Nullable(FixedString(4)) column")
    func insertNullableFixedString() throws {
        let optionals: [Data?] = [Data([1, 2, 3, 4]), nil, Data([255, 255, 255, 255])]
        let column = try ClickHouseClient.toInternalColumn(.nullableFixedString(length: 4, optionals.map(ClickHouseNullable.init)))
        let typed = try #require(column as? ClickHouseNullableColumn)
        #expect(typed.spec == .nullable(of: .fixedString(length: 4)))
        let inner = try #require(typed.inner as? ClickHouseFixedStringColumn)
        #expect(inner.length == 4)
        #expect(inner.values[0] == Data([1, 2, 3, 4]))
        #expect(inner.values[2] == Data([255, 255, 255, 255]))
    }

    @Test("INSERT .nullableFixedString throws when a non-nil element doesn't match the declared length")
    func insertNullableFixedStringMismatchedLengthThrows() {
        let bad: [Data?] = [Data([1, 2, 3]), nil]  // 3 bytes when length is 4
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.toInternalColumn(.nullableFixedString(length: 4, bad.map(ClickHouseNullable.init)))
        }
    }

    // MARK: - SELECT side: Nullable(IPv4)

    @Test("SELECT Nullable(IPv4) maps to .nullableIPv4 with mask applied")
    func selectNullableIPv4() throws {
        let inner = ClickHouseFixedWidthIntegerColumn<UInt32>(spec: .ipv4, values: [0x7F00_0001, 0, 0xC633_6408])
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .ipv4),
            innerSpec: .ipv4,
            nullMask: [false, true, false],
            inner: inner
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ip", internalColumn: column)
        guard case .nullableIPv4(let values) = publicColumn.values else {
            Issue.record("expected .nullableIPv4 case")
            return
        }
        #expect(values.map(\.value) == [0x7F00_0001, nil, 0xC633_6408])
    }

    // MARK: - SELECT side: Nullable(IPv6)

    @Test("SELECT Nullable(IPv6) maps to .nullableIPv6 with mask applied to 16-byte raw values")
    func selectNullableIPv6() throws {
        let zero = Data(repeating: 0, count: 16)
        let loopback = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let inner = ClickHouseFixedStringColumn(spec: .ipv6, length: 16, values: [zero, loopback])
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .ipv6),
            innerSpec: .ipv6,
            nullMask: [true, false],
            inner: inner
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ip", internalColumn: column)
        guard case .nullableIPv6(let values) = publicColumn.values else {
            Issue.record("expected .nullableIPv6 case")
            return
        }
        #expect(values.map(\.value) == [nil, loopback])
    }

    // MARK: - SELECT side: Nullable(FixedString)

    @Test("SELECT Nullable(FixedString(N)) maps to .nullableFixedString carrying the byte length")
    func selectNullableFixedString() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let inner = ClickHouseFixedStringColumn(
            spec: .fixedString(length: 4), length: 4,
            values: [bytes, Data(repeating: 0, count: 4)]
        )
        let column = ClickHouseNullableColumn(
            spec: .nullable(of: .fixedString(length: 4)),
            innerSpec: .fixedString(length: 4),
            nullMask: [false, true],
            inner: inner
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "h", internalColumn: column)
        guard case .nullableFixedString(let length, let values) = publicColumn.values else {
            Issue.record("expected .nullableFixedString case")
            return
        }
        #expect(length == 4)
        #expect(values.map(\.value) == [bytes, nil])
    }

    // MARK: - End-to-end wire round-trip

    @Test("Nullable(IPv4) round-trips through encode/decode preserving every present and null value")
    func wireRoundTripNullableIPv4() throws {
        let original: [UInt32?] = [0x7F00_0001, nil, 0xC633_6408, nil, 0xFFFF_FFFF]
        let column = try ClickHouseClient.toInternalColumn(.nullableIPv4(original.map(ClickHouseNullable.init)))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .nullable(of: .ipv4), rows: original.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ip", internalColumn: decoded)
        guard case .nullableIPv4(let restored) = publicColumn.values else {
            Issue.record("expected .nullableIPv4 case")
            return
        }
        #expect(restored.map(\.value) == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("Nullable(IPv6) round-trips through encode/decode preserving 16-byte addresses")
    func wireRoundTripNullableIPv6() throws {
        let google = Data([0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88])
        let cloudflare = Data([0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11])
        let original: [Data?] = [google, nil, cloudflare]
        let column = try ClickHouseClient.toInternalColumn(.nullableIPv6(original.map(ClickHouseNullable.init)))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .nullable(of: .ipv6), rows: original.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "ip", internalColumn: decoded)
        guard case .nullableIPv6(let restored) = publicColumn.values else {
            Issue.record("expected .nullableIPv6 case")
            return
        }
        #expect(restored.count == 3)
        #expect(restored[0].value == google)
        #expect(restored[1] == nil)
        #expect(restored[2].value == cloudflare)
        #expect(buffer.readableBytes == 0)
    }

    @Test("Nullable(FixedString(N)) round-trips through encode/decode with byte length preserved")
    func wireRoundTripNullableFixedString() throws {
        let length = 8
        let alpha = Data(repeating: 0xAA, count: length)
        let beta = Data(repeating: 0xBB, count: length)
        let original: [Data?] = [alpha, nil, beta, nil]
        let column = try ClickHouseClient.toInternalColumn(.nullableFixedString(length: length, original.map(ClickHouseNullable.init)))
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .nullable(of: .fixedString(length: length)), rows: original.count, from: &buffer
        )
        let publicColumn = try ClickHouseSelectColumn.from(name: "h", internalColumn: decoded)
        guard case .nullableFixedString(let restoredLength, let restored) = publicColumn.values else {
            Issue.record("expected .nullableFixedString case")
            return
        }
        #expect(restoredLength == length)
        #expect(restored.count == 4)
        #expect(restored[0].value == alpha)
        #expect(restored[1] == nil)
        #expect(restored[2].value == beta)
        #expect(restored[3] == nil)
        #expect(buffer.readableBytes == 0)
    }

}
