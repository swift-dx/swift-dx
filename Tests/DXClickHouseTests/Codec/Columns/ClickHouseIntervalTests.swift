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

@Suite("ClickHouse Interval types (all 11 kinds)")
struct ClickHouseIntervalTests {

    // MARK: - IntervalKind

    @Test(
        "every IntervalKind round-trips its typeName via init(typeName:)",
        arguments: ClickHouseIntervalKind.allCases
    )
    func intervalKindTypeNameRoundTrip(_ kind: ClickHouseIntervalKind) {
        let name = kind.typeName
        let parsed = ClickHouseIntervalKind(typeName: name)
        #expect(parsed == kind)
    }

    @Test("IntervalKind.init(typeName:) returns nil for unknown names")
    func intervalKindUnknownNameReturnsNil() {
        #expect(ClickHouseIntervalKind(typeName: "IntervalCentury") == nil)
        #expect(ClickHouseIntervalKind(typeName: "Interval") == nil)
        #expect(ClickHouseIntervalKind(typeName: "Year") == nil)
        #expect(ClickHouseIntervalKind(typeName: "") == nil)
    }

    @Test("IntervalKind.allCases covers all 11 ClickHouse interval types")
    func intervalKindHasElevenCases() {
        #expect(ClickHouseIntervalKind.allCases.count == 11)
    }

    // MARK: - Spec + parser

    @Test(
        "every IntervalX type name parses to .interval(kind: corresponding kind)",
        arguments: ClickHouseIntervalKind.allCases
    )
    func intervalTypeNameParses(_ kind: ClickHouseIntervalKind) throws {
        let parsed = try ClickHouseTypeNameParser.parse(kind.typeName)
        #expect(parsed == .interval(kind: kind))
    }

    @Test(
        "every interval spec produces its IntervalX type name via the Spec+TypeName extension",
        arguments: ClickHouseIntervalKind.allCases
    )
    func intervalSpecTypeNameProduction(_ kind: ClickHouseIntervalKind) {
        let spec = ClickHouseColumnSpec.interval(kind: kind)
        #expect(spec.typeName == kind.typeName)
    }

    @Test("an unrecognized Interval name (e.g., IntervalCentury) throws unknownTypeName, not an Interval misparse")
    func unknownIntervalNameThrows() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseTypeNameParser.parse("IntervalCentury")
        }
    }

    // MARK: - Spec equality

    @Test("intervals of different kinds are NOT equal")
    func intervalKindEqualityRejects() {
        #expect(ClickHouseColumnSpec.interval(kind: .day) != .interval(kind: .hour))
        #expect(ClickHouseColumnSpec.interval(kind: .second) != .interval(kind: .millisecond))
    }

    @Test("intervals of the same kind ARE equal")
    func intervalKindEqualityAccepts() {
        #expect(ClickHouseColumnSpec.interval(kind: .day) == .interval(kind: .day))
    }

    // MARK: - Wire round-trip

    @Test("Interval column round-trips Int64 wire bytes via the registry")
    func intervalWireRoundTrips() throws {
        let original: [Int64] = [Int64.min, -1, 0, 1, 42, 86_400, Int64.max]
        let column = ClickHouseFixedWidthIntegerColumn<Int64>(
            spec: .interval(kind: .day),
            values: original
        )
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == original.count * 8)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .interval(kind: .day),
            rows: original.count,
            from: &buffer
        )
        let typed = try #require(decoded as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == original)
        #expect(buffer.readableBytes == 0)
    }

    // MARK: - Public API integration

    @Test(
        "public typed-INSERT API converts .interval to a FixedWidthInteger<Int64> column with .interval(kind:) spec",
        arguments: ClickHouseIntervalKind.allCases
    )
    func publicAPIConvertsInterval(_ kind: ClickHouseIntervalKind) throws {
        let values: [Int64] = [1, 7, 30]
        let column = try ClickHouseClient.toInternalColumn(.interval(kind: kind, values: values))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == values)
        #expect(typed.spec == .interval(kind: kind))
    }

    @Test("an empty .interval([]) produces a 0-row column")
    func emptyIntervalProducesEmptyColumn() throws {
        let column = try ClickHouseClient.toInternalColumn(.interval(kind: .second, values: []))
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values.isEmpty)
        #expect(typed.spec == .interval(kind: .second))
    }

    @Test("public typed-INSERT API preserves IntervalNanosecond extreme values (Int64 boundaries)")
    func publicAPIPreservesNanosecondBoundaries() throws {
        let extremes: [Int64] = [Int64.min, Int64.max, 0, -1_000_000_000, 1_000_000_000]
        let column = try ClickHouseClient.toInternalColumn(
            .interval(kind: .nanosecond, values: extremes)
        )
        let typed = try #require(column as? ClickHouseFixedWidthIntegerColumn<Int64>)
        #expect(typed.values == extremes)
    }

}
