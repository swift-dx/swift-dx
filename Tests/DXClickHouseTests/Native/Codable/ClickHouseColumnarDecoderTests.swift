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

// Unit tests for the columnar fast-path decoder. These exercise the
// decoder via direct construction of `ClickHouseColumnarDecoderState`
// + `ClickHouseColumnarDecoder` rather than the streaming SELECT
// surface so the behaviour can be asserted without a live ClickHouse
// connection. Network-driven tests for `selectStreamFast` live in
// IntegrationTests.

// Typed outcome for "execute this throwing block and tell me what
// happened" — replaces the Error? capture pattern other test files
// use so this suite stays inside the no-Optionals discipline.
enum ColumnarDecodeOutcome<Value: Sendable>: Sendable {

    case success(Value)
    case failure(Error)

}

func captureOutcome<T: Sendable>(_ body: () throws -> T) -> ColumnarDecodeOutcome<T> {
    do {
        return .success(try body())
    } catch {
        return .failure(error)
    }
}

func decodeAllRows<T: Decodable & Sendable>(_ type: T.Type, columns: [ClickHouseSelectColumn]) throws -> [T] {
    let state = try ClickHouseColumnarDecoderState(columns: columns, keyDecodingStrategy: .useDefaultKeys)
    let decoder = ClickHouseColumnarDecoder(state: state)
    var rows: [T] = []
    rows.reserveCapacity(state.rowCount)
    for rowIndex in 0..<state.rowCount {
        state.rowIndex = rowIndex
        rows.append(try T(from: decoder))
    }
    return rows
}

@Suite("ClickHouseColumnarDecoder — primitive types")
struct ClickHouseColumnarDecoderPrimitiveTests {

    private struct PrimitivesRow: Codable, Equatable, Sendable {

        let id: UInt64
        let name: String
        let active: Bool
        let temperature: Double
        let count: Int32
        let tag: UInt8

    }

    @Test("encoder → columnar-decoder round-trip preserves every primitive across multiple rows")
    func roundTripPreservesPrimitiveValues() throws {
        let rows: [PrimitivesRow] = [
            PrimitivesRow(id: 1, name: "alpha", active: true, temperature: 0.5, count: 10, tag: 200),
            PrimitivesRow(id: 2, name: "beta", active: false, temperature: -1.25, count: 20, tag: 100),
            PrimitivesRow(id: 3, name: "gamma", active: true, temperature: 99.99, count: 30, tag: 50),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try decodeAllRows(PrimitivesRow.self, columns: columns)
        #expect(decoded == rows)
    }

    @Test("columnar decode against an empty column set returns an empty array — no rows materialized")
    func emptyColumnsReturnsEmpty() throws {
        let decoded = try decodeAllRows(PrimitivesRow.self, columns: [])
        #expect(decoded.isEmpty)
    }

    @Test("columnar decode of a single row returns exactly one element with the expected values")
    func singleRowDecode() throws {
        let row = PrimitivesRow(id: 42, name: "only", active: true, temperature: 3.14, count: 7, tag: 1)
        let entries = try ClickHouseRowEncoder().encode([row])
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try decodeAllRows(PrimitivesRow.self, columns: columns)
        #expect(decoded == [row])
    }

    @Test("columnar decode of one million rows yields the expected sequence and stays within bounds")
    func millionRowDecode() throws {
        let totalRows = 1_000_000
        let ids = (0..<totalRows).map { UInt64($0) }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64(ids))
        ]
        struct IDOnly: Decodable, Equatable, Sendable {

            let id: UInt64

        }
        let state = try ClickHouseColumnarDecoderState(columns: columns, keyDecodingStrategy: .useDefaultKeys)
        let decoder = ClickHouseColumnarDecoder(state: state)
        var first = UInt64.max
        var last = UInt64.max
        var observed = 0
        for rowIndex in 0..<state.rowCount {
            state.rowIndex = rowIndex
            let row = try IDOnly(from: decoder)
            if observed == 0 { first = row.id }
            last = row.id
            observed += 1
        }
        #expect(observed == totalRows)
        #expect(first == 0)
        #expect(last == UInt64(totalRows - 1))
    }

    @Test("malformed Decodable struct asking for a missing column surfaces DecodingError.keyNotFound")
    func malformedStructMissingColumn() throws {
        struct Row: Decodable, Sendable {

            let id: UInt64
            let missing: String

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1]))
        ]
        let outcome = captureOutcome { try decodeAllRows(Row.self, columns: columns) }
        switch outcome {
        case .success: Issue.record("expected DecodingError.keyNotFound; succeeded instead")
        case .failure(let error):
            if case DecodingError.keyNotFound(let key, _) = error {
                #expect(key.stringValue == "missing")
            } else {
                Issue.record("expected DecodingError.keyNotFound; got \(error)")
            }
        }
    }

    @Test("type-mismatched Decodable struct surfaces DecodingError.typeMismatch")
    func malformedStructTypeMismatch() throws {
        struct Row: Decodable, Sendable {

            let id: Int64

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2]))
        ]
        let outcome = captureOutcome { try decodeAllRows(Row.self, columns: columns) }
        switch outcome {
        case .success: Issue.record("expected DecodingError.typeMismatch; succeeded instead")
        case .failure(let error):
            if case DecodingError.typeMismatch = error {
                // ok
            } else {
                Issue.record("expected DecodingError.typeMismatch; got \(error)")
            }
        }
    }

    @Test("Swift `Int` field is rejected with a typed error pointing at platform-dependent width")
    func swiftIntFieldRejected() throws {
        struct Row: Decodable, Sendable {

            let id: Int

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "Int64", values: .int64([1]))
        ]
        let outcome = captureOutcome { try decodeAllRows(Row.self, columns: columns) }
        switch outcome {
        case .success: Issue.record("expected rowEncoderUnsupportedType; succeeded instead")
        case .failure(let error):
            if case ClickHouseError.rowEncoderUnsupportedType(let description, _, _) = error {
                #expect(description == "Int")
            } else {
                Issue.record("expected rowEncoderUnsupportedType; got \(error)")
            }
        }
    }

    @Test("mismatched column row counts in input surface as rowDecoderMismatchedColumnRowCounts before any row construction begins")
    func mismatchedColumnRowCountsRejectedAtConstruction() throws {
        struct Row: Decodable, Sendable {

            let id: UInt64
            let name: String

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2, 3])),
            ClickHouseSelectColumn(name: "name", typeName: "String", values: .string(["alpha", "beta"])),
        ]
        let outcome = captureOutcome { try decodeAllRows(Row.self, columns: columns) }
        switch outcome {
        case .success: Issue.record("expected rowDecoderMismatchedColumnRowCounts; succeeded instead")
        case .failure(let error):
            if case ClickHouseError.rowDecoderMismatchedColumnRowCounts(let columnName, let expected, let actual) = error {
                #expect(columnName == "name")
                #expect(expected == 3)
                #expect(actual == 2)
            } else {
                Issue.record("expected rowDecoderMismatchedColumnRowCounts; got \(error)")
            }
        }
    }

}

@Suite("ClickHouseColumnarDecoder — Nullable / Optional fields")
struct ClickHouseColumnarDecoderNullableTests {

    struct NullableProbeResult: Sendable, Equatable {

        let id: UInt64
        let isNil: Bool
        let name: String

    }

    private enum NullableProbeKey: String, CodingKey {

        case id
        case name

    }

    private func probeNullableRow(decoder: ClickHouseColumnarDecoder) throws -> NullableProbeResult {
        let container = try decoder.container(keyedBy: NullableProbeKey.self)
        let id = try container.decode(UInt64.self, forKey: .id)
        let isNil = try container.decodeNil(forKey: .name)
        let name = isNil ? "" : try container.decode(String.self, forKey: .name)
        return NullableProbeResult(id: id, isNil: isNil, name: name)
    }

    private func probeAllRows(state: ClickHouseColumnarDecoderState, decoder: ClickHouseColumnarDecoder) throws -> [NullableProbeResult] {
        var probed: [NullableProbeResult] = []
        probed.reserveCapacity(state.rowCount)
        for rowIndex in 0..<state.rowCount {
            state.rowIndex = rowIndex
            probed.append(try probeNullableRow(decoder: decoder))
        }
        return probed
    }

    @Test("Nullable(String) column with mixed null/non-null rows decodes through ClickHouseNullable preserving per-row presence")
    func nullableStringMixedDecodes() throws {
        // The probe uses two surfaces to avoid Optional in the test
        // target: `decodeNil` exposes presence; `decode(String)`
        // returns the unwrapped value when present.
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2, 3, 4])),
            ClickHouseSelectColumn(name: "name", typeName: "Nullable(String)", values: .nullableString([
                .present("alpha"), .absent, .present("gamma"), .absent,
            ])),
        ]
        let state = try ClickHouseColumnarDecoderState(columns: columns, keyDecodingStrategy: .useDefaultKeys)
        let decoder = ClickHouseColumnarDecoder(state: state)
        let probed = try probeAllRows(state: state, decoder: decoder)
        #expect(probed == [
            NullableProbeResult(id: 1, isNil: false, name: "alpha"),
            NullableProbeResult(id: 2, isNil: true, name: ""),
            NullableProbeResult(id: 3, isNil: false, name: "gamma"),
            NullableProbeResult(id: 4, isNil: true, name: ""),
        ])
    }

    @Test("Nullable column read into a non-Optional target throws DecodingError.valueNotFound at the null row")
    func nullableIntoNonOptionalThrows() throws {
        struct Row: Decodable, Sendable {

            let id: UInt64
            let name: String

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "name", typeName: "Nullable(String)", values: .nullableString([
                .present("alpha"), .absent,
            ])),
        ]
        let outcome = captureOutcome { try decodeAllRows(Row.self, columns: columns) }
        switch outcome {
        case .success: Issue.record("expected DecodingError.valueNotFound; succeeded instead")
        case .failure(let error):
            if case DecodingError.valueNotFound = error {
                // ok
            } else {
                Issue.record("expected DecodingError.valueNotFound; got \(error)")
            }
        }
    }

}

@Suite("ClickHouseColumnarDecoder — Date / DateTime / DateTime64 / UUID")
struct ClickHouseColumnarDecoderDateUUIDTests {

    @Test("DateTime column decodes into Date field preserving the timestamp")
    func dateTimeDecodesIntoDate() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let ts: Date

        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "ts", typeName: "DateTime", values: .dateTime([timestamp, timestamp])),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [Row(id: 1, ts: timestamp), Row(id: 2, ts: timestamp)])
    }

    @Test("Date column decodes into Date field — typed overload handles the Date variant")
    func dateColumnDecodesIntoDate() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let day: Date

        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1])),
            ClickHouseSelectColumn(name: "day", typeName: "Date", values: .date([timestamp])),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [Row(id: 1, day: timestamp)])
    }

    @Test("DateTime64 nanoseconds column decodes into Int64 field via raw value mapping")
    func dateTime64NanosDecodesIntoInt64() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let nanos: Int64

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "nanos", typeName: "DateTime64(9)", values: .dateTime64Nanoseconds([
                ClickHouseNanoseconds(Int64(1_700_000_000_000_000_000)),
                ClickHouseNanoseconds(Int64(1_700_000_000_000_000_001)),
            ], precision: 9)),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [
            Row(id: 1, nanos: 1_700_000_000_000_000_000),
            Row(id: 2, nanos: 1_700_000_000_000_000_001),
        ])
    }

    @Test("UUID column decodes into UUID field via typed overload")
    func uuidColumnDecodesIntoUUID() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let token: UUID

        }
        let one = UUID()
        let two = UUID()
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "token", typeName: "UUID", values: .uuid([one, two])),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [Row(id: 1, token: one), Row(id: 2, token: two)])
    }

}

@Suite("ClickHouseColumnarDecoder — Array / Map / LowCardinality")
struct ClickHouseColumnarDecoderContainerTests {

    @Test("Map(String, String) column decodes into [String: String] field across multiple rows")
    func mapStringStringDecodes() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let attributes: [String: String]

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "attributes", typeName: "Map(String, String)", values: .mapStringString([
                ["service": "svc-1", "region": "ap-southeast-2"],
                ["service": "svc-2", "region": "ap-southeast-2"],
            ])),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [
            Row(id: 1, attributes: ["service": "svc-1", "region": "ap-southeast-2"]),
            Row(id: 2, attributes: ["service": "svc-2", "region": "ap-southeast-2"]),
        ])
    }

    @Test("LowCardinality(String) column decodes into String field through the unified String case")
    func lowCardinalityStringDecodes() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let environment: String

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2, 3])),
            ClickHouseSelectColumn(name: "environment", typeName: "LowCardinality(String)", values: .lowCardinalityString([
                "production", "staging", "production",
            ])),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [
            Row(id: 1, environment: "production"),
            Row(id: 2, environment: "staging"),
            Row(id: 3, environment: "production"),
        ])
    }

    @Test("LowCardinality(String) indexed view decodes into String field via dictionary subscript")
    func lowCardinalityStringIndexedDecodes() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let environment: String

        }
        let view = ClickHouseLowCardinalityStringView(
            dictionary: ["production", "staging"],
            indices: [0, 1, 0]
        )
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2, 3])),
            ClickHouseSelectColumn(name: "environment", typeName: "LowCardinality(String)", values: .lowCardinalityStringIndexed(view)),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [
            Row(id: 1, environment: "production"),
            Row(id: 2, environment: "staging"),
            Row(id: 3, environment: "production"),
        ])
    }

    @Test("Map(String, String) indexed storage decodes lazily into [String: String]")
    func mapStringStringIndexedDecodes() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let attributes: [String: String]

        }
        let storage = ClickHouseMapStringStringStorage(
            keys: .direct(["service", "region", "service", "region"]),
            values: ["svc-1", "ap-southeast-2", "svc-2", "ap-southeast-2"],
            offsets: [2, 4]
        )
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "attributes", typeName: "Map(String, String)", values: .mapStringStringIndexed(storage)),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [
            Row(id: 1, attributes: ["service": "svc-1", "region": "ap-southeast-2"]),
            Row(id: 2, attributes: ["service": "svc-2", "region": "ap-southeast-2"]),
        ])
    }

    @Test("Map(LowCardinality(String), String) indexed storage decodes lazily into [String: String]")
    func mapLCStringStringIndexedDecodes() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let attributes: [String: String]

        }
        let storage = ClickHouseMapStringStringStorage(
            keys: .lowCardinality(
                dictionary: ["service", "region"],
                indices: [0, 1, 0, 1]
            ),
            values: ["svc-1", "ap-southeast-2", "svc-2", "ap-southeast-2"],
            offsets: [2, 4]
        )
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "attributes", typeName: "Map(LowCardinality(String), String)", values: .mapStringStringIndexed(storage)),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [
            Row(id: 1, attributes: ["service": "svc-1", "region": "ap-southeast-2"]),
            Row(id: 2, attributes: ["service": "svc-2", "region": "ap-southeast-2"]),
        ])
    }

    @Test("Array(UInt64) column decodes into [UInt64] field")
    func arrayUInt64Decodes() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let values: [UInt64]

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2])),
            ClickHouseSelectColumn(name: "values", typeName: "Array(UInt64)", values: .arrayOfUInt64([
                [10, 20, 30], [40, 50],
            ])),
        ]
        let decoded = try decodeAllRows(Row.self, columns: columns)
        #expect(decoded == [
            Row(id: 1, values: [10, 20, 30]),
            Row(id: 2, values: [40, 50]),
        ])
    }

}

@Suite("ClickHouseColumnarDecoder — slot cache behaviour")
struct ClickHouseColumnarDecoderSlotCacheTests {

    @Test("the slot cache is populated on first row and reused across subsequent rows of the same block")
    func slotCachePopulatesOnFirstRowAndReuses() throws {
        struct Row: Decodable, Equatable, Sendable {

            let id: UInt64
            let name: String

        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2, 3])),
            ClickHouseSelectColumn(name: "name", typeName: "String", values: .string(["a", "b", "c"])),
        ]
        let state = try ClickHouseColumnarDecoderState(columns: columns, keyDecodingStrategy: .useDefaultKeys)
        let decoder = ClickHouseColumnarDecoder(state: state)
        state.rowIndex = 0
        _ = try Row(from: decoder)
        #expect(state.slot(for: "id") == .present(0))
        #expect(state.slot(for: "name") == .present(1))
        state.rowIndex = 1
        let row2 = try Row(from: decoder)
        #expect(row2 == Row(id: 2, name: "b"))
        state.rowIndex = 2
        let row3 = try Row(from: decoder)
        #expect(row3 == Row(id: 3, name: "c"))
    }

    @Test("absent CodingKey lookups are cached as .absent so repeated missing-column probes pay the lookup cost only once")
    func absentSlotIsCached() throws {
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1]))
        ]
        let state = try ClickHouseColumnarDecoderState(columns: columns, keyDecodingStrategy: .useDefaultKeys)
        let first = state.slot(for: "nonexistent")
        #expect(first == .absent)
        let second = state.slot(for: "nonexistent")
        #expect(second == .absent)
    }

    @Test("convertFromSnakeCase strategy is applied during slot resolution and cached")
    func snakeCaseStrategyAppliedAndCached() throws {
        let columns = [
            ClickHouseSelectColumn(name: "kinesis_shard_id", typeName: "String", values: .string(["shard-0"]))
        ]
        let state = try ClickHouseColumnarDecoderState(columns: columns, keyDecodingStrategy: .convertFromSnakeCase)
        let slot = state.slot(for: "kinesisShardId")
        #expect(slot == .present(0))
        let cached = state.slot(for: "kinesisShardId")
        #expect(cached == .present(0))
    }

}
