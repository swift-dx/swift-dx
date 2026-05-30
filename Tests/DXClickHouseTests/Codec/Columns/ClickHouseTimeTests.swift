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

@Suite("ClickHouse Time / Time64")
struct ClickHouseTimeTests {

    @Test("Time typeName + parser round-trip")
    func timeTypeNameRoundTrip() throws {
        #expect(ClickHouseColumnSpec.time.typeName == "Time")
        let parsed = try ClickHouseTypeNameParser.parse("Time")
        #expect(parsed == .time)
    }

    @Test("Time64 typeName carries precision and parses back")
    func time64TypeNameRoundTrip() throws {
        let spec = ClickHouseColumnSpec.time64(precision: 6)
        #expect(spec.typeName == "Time64(6)")
        let parsed = try ClickHouseTypeNameParser.parse("Time64(6)")
        #expect(parsed == .time64(precision: 6))
    }

    @Test("Time64 precision 0 (whole seconds) round-trips")
    func time64PrecisionZero() throws {
        #expect(ClickHouseColumnSpec.time64(precision: 0).typeName == "Time64(0)")
        let parsed = try ClickHouseTypeNameParser.parse("Time64(0)")
        #expect(parsed == .time64(precision: 0))
    }

    @Test("Time decodes as a 4-byte little-endian Int32 column via the registry")
    func timeDecodesAsInt32Column() throws {
        let original: [Int32] = [0, 3600, 43200, 86399, -86399, -1]
        let column = ClickHouseFixedWidthIntegerColumn<Int32>(spec: .time, values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == original.count * 4)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .time, rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("Time64 decodes as an 8-byte little-endian Int64 column via the registry")
    func time64DecodesAsInt64Column() throws {
        // For Time64 with precision 6, values are tick counts (microseconds within a day).
        let original: [Int64] = [0, 1_000_000, 86_399_999_999, -86_399_999_999]
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(spec: .time64(precision: 6), values: original)
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == original.count * 8)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .time64(precision: 6), rows: original.count, from: &buffer)
        let typed = try #require(decoded as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == original)
    }

    @Test("public typed-INSERT API converts .time to a FixedWidthInteger<Int32> column with .time spec")
    func publicAPIConvertsTime() throws {
        let column = try ClickHouseClient.toInternalColumn(.time([0, 3600, 86399]))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(typed.values == [0, 3600, 86399])
        #expect(typed.spec == .time)
    }

    @Test("public typed-INSERT API converts .time64 to a FixedWidthInteger<Int64> column with the right precision")
    func publicAPIConvertsTime64() throws {
        let column = try ClickHouseClient.toInternalColumn(.time64([0, 1_000_000, 999_999_999], precision: 9))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == [0, 1_000_000, 999_999_999])
        #expect(typed.spec == .time64(precision: 9))
    }

    @Test("Time and Time64 with different precisions are distinguishable specs")
    func differentPrecisionsAreNotEqual() {
        #expect(ClickHouseColumnSpec.time64(precision: 3) != .time64(precision: 6))
        #expect(ClickHouseColumnSpec.time != .time64(precision: 0))
    }

}
