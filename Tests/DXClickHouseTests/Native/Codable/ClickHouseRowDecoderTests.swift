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

@Suite("ClickHouseRowDecoder — primitive types")
struct ClickHouseRowDecoderTests {

    private struct PrimitivesRow: Codable, Equatable, Sendable {

        let id: UInt64
        let name: String
        let active: Bool
        let temperature: Double
        let count: Int32
        let tag: UInt8

    }

    @Test("encoder → decoder round-trip preserves every primitive value across multiple rows")
    func encoderToDecoderRoundTrip() throws {
        let rows: [PrimitivesRow] = [
            PrimitivesRow(id: 1, name: "alpha", active: true, temperature: 0.5, count: 10, tag: 200),
            PrimitivesRow(id: 2, name: "beta", active: false, temperature: -1.25, count: 20, tag: 100),
            PrimitivesRow(id: 3, name: "gamma", active: true, temperature: 99.99, count: 30, tag: 50),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        // Convert ColumnEntry → SelectColumn (decoder's input shape).
        let columns = entries.map { entry in
            ClickHouseSelectColumn(
                name: entry.name,
                typeName: "<test>",
                values: entry.values
            )
        }
        let decoded = try ClickHouseRowDecoder().decode(PrimitivesRow.self, from: columns)
        #expect(decoded == rows)
    }

    @Test("decode against an empty column set returns an empty array — no rows materialized")
    func decodeEmptyColumnsReturnsEmpty() throws {
        let decoded = try ClickHouseRowDecoder().decode(PrimitivesRow.self, from: [])
        #expect(decoded.isEmpty)
    }

    @Test("decoding a column whose Swift target type doesn't match its native type surfaces codableDecodingFailure with kind: .typeMismatch")
    func typeMismatchSurfacesAsDecodingError() throws {
        // Column 'id' is .uint64, but the row asks for Int64.
        struct Row: Decodable, Sendable {
            let id: Int64
        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1, 2]))
        ]
        var thrown: Error?
        do {
            _ = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.codableDecodingFailure(let kind, _, _, _) = received {
            #expect(kind == .typeMismatch)
        } else {
            Issue.record("expected codableDecodingFailure(typeMismatch); got \(received)")
        }
    }

    @Test("decoding a Decodable type asking for a column not in the SELECT result surfaces codableDecodingFailure with kind: .keyNotFound")
    func missingColumnSurfacesAsKeyNotFound() throws {
        struct Row: Decodable, Sendable {
            let id: UInt64
            let missing: String
        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "UInt64", values: .uint64([1]))
        ]
        var thrown: Error?
        do {
            _ = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.codableDecodingFailure(let kind, let typeName, _, _) = received {
            #expect(kind == .keyNotFound)
            #expect(typeName == "missing")
        } else {
            Issue.record("expected codableDecodingFailure(keyNotFound); got \(received)")
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
            ClickHouseSelectColumn(name: "name", typeName: "String", values: .string(["alpha", "beta"])),  // only 2 entries
        ]
        var thrown: Error?
        do {
            _ = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.rowDecoderMismatchedColumnRowCounts(let columnName, let expected, let actual) = received {
            #expect(columnName == "name")
            #expect(expected == 3)
            #expect(actual == 2)
        } else {
            Issue.record("expected rowDecoderMismatchedColumnRowCounts; got \(received)")
        }
    }

    @Test("storage row count comes from the actual column array length even for variants the decoder doesn't decode (no silent zero)")
    func storageRowCountReflectsActualColumnLengthForUndecoded() throws {
        // Pre-fix bug: `ClickHouseRowDecoderStorage` used a private
        // switch with a `default → 0` branch for any Values variant
        // it didn't list. Common types like `.date32`, `.dateTime64`,
        // `.decimal*`, `.arrayOf*` fell into that default. Two failure
        // modes resulted:
        //   1. If a single `.date32` column was passed, rowCount became
        //      0, so the row decoder iterated `0..<0` and returned an
        //      empty result silently — the user had no signal that
        //      rows existed.
        //   2. Mixed [.int64, .date32] columns reported a phantom
        //      mismatch (expected: N, actual: 0) for a column the user
        //      may not even decode.
        // Both are silent-data-loss / confusing-error bugs. The fix is
        // an exhaustive `rowCount` property so every Values variant is
        // counted at compile-time-enforced exhaustiveness.
        struct Row: Decodable, Equatable {

            let id: Int64

        }

        // Three rows in each column; a `.date32` column of length 3
        // pre-fix would report rowCount = 0 and trigger a mismatch.
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "Int64", values: .int64([10, 20, 30])),
            ClickHouseSelectColumn(name: "ts", typeName: "Date32", values: .nullableDate32([nil, 0, 1])),
        ]
        let decoded = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        #expect(decoded.count == 3, "decoder should see 3 rows; pre-fix it would have thrown a phantom mismatch")
        #expect(decoded.map(\.id) == [10, 20, 30])
    }

    @Test("round-trip via encoder→decoder preserves exact values for 100 rows of varied primitive content")
    func roundTripPreservesValuesAtScale() throws {
        var rows: [PrimitivesRow] = []
        rows.reserveCapacity(100)
        for index in 0..<100 {
            let id = UInt64(index)
            let name = "row-\(index)"
            let active = index % 2 == 0
            let temperature = Double(index) * 0.123
            let count = Int32(index - 50)
            let tag = UInt8(index % 256)
            rows.append(PrimitivesRow(
                id: id, name: name, active: active,
                temperature: temperature, count: count, tag: tag
            ))
        }
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(PrimitivesRow.self, from: columns)
        #expect(decoded == rows)
    }

    @Test("Phase 2 round-trip: Optional<String> with mixed nil/non-nil values preserves per-row presence through encoder → decoder")
    func optionalStringMixedRoundTrip() throws {
        struct Row: Codable, Equatable, Sendable {
            let id: UInt64
            let name: String?
        }
        let rows: [Row] = [
            Row(id: 1, name: "alpha"),
            Row(id: 2, name: nil),
            Row(id: 3, name: "gamma"),
            Row(id: 4, name: nil),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        #expect(decoded == rows)
    }

    @Test("Phase 2 round-trip: multiple Optional fields of different types in the same row preserve per-row presence")
    func multipleOptionalFieldsRoundTrip() throws {
        struct Row: Codable, Equatable, Sendable {
            let id: UInt64
            let name: String?
            let count: Int32?
            let active: Bool?
            let value: Double?
        }
        let rows: [Row] = [
            Row(id: 1, name: "a", count: 10, active: true, value: 0.5),
            Row(id: 2, name: nil, count: 20, active: nil, value: nil),
            Row(id: 3, name: "c", count: nil, active: false, value: -1.25),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        #expect(decoded == rows)
    }

    @Test("decoder reading a Nullable column where the value at this row is nil into a non-Optional target throws codableDecodingFailure with kind: .valueNotFound")
    func nullableColumnIntoNonOptionalThrowsValueNotFound() throws {
        struct Row: Decodable, Sendable {
            let name: String
        }
        // Build a Nullable(String) column containing nil for the
        // first row; ask the decoder to return Row.name as
        // non-Optional String.
        let columns = [
            ClickHouseSelectColumn(name: "name", typeName: "Nullable(String)", values: .nullableString([nil, "hello"]))
        ]
        var thrown: Error?
        do {
            _ = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.codableDecodingFailure(let kind, _, _, _) = received {
            #expect(kind == .valueNotFound)
        } else {
            Issue.record("expected codableDecodingFailure(valueNotFound); got \(received)")
        }
    }

    @Test("Phase 2B round-trip: a struct with a non-Optional Date field encodes as DateTime then decodes back, preserving the timestamp value across the round trip")
    func nonOptionalDateRoundTrip() throws {
        struct Row: Codable, Sendable {
            let id: UInt64
            let createdAt: Date
        }
        // ClickHouse DateTime is second-precision; pre-truncate to
        // seconds so the round-trip equality check is deterministic.
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
        let rows: [Row] = [
            Row(id: 1, createdAt: now),
            Row(id: 2, createdAt: now.addingTimeInterval(60)),
            Row(id: 3, createdAt: now.addingTimeInterval(3600)),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        // Compare ids and timestamps exactly.
        #expect(decoded.count == 3)
        for (input, output) in zip(rows, decoded) {
            #expect(input.id == output.id)
            #expect(input.createdAt.timeIntervalSince1970 == output.createdAt.timeIntervalSince1970,
                    "Date round-trip must preserve timestamp value (within DateTime second precision)")
        }
    }

    @Test("Phase 2B round-trip: Optional<Date> field with mixed nil/non-nil values produces a Nullable(DateTime) column and decodes back preserving per-row presence")
    func optionalDateRoundTrip() throws {
        struct Row: Codable, Equatable, Sendable {
            let id: UInt64
            let scheduledAt: Date?
        }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [Row] = [
            Row(id: 1, scheduledAt: baseDate),
            Row(id: 2, scheduledAt: nil),
            Row(id: 3, scheduledAt: baseDate.addingTimeInterval(86_400)),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        #expect(decoded.count == 3)
        #expect(decoded[0].scheduledAt?.timeIntervalSince1970 == rows[0].scheduledAt?.timeIntervalSince1970)
        #expect(decoded[1].scheduledAt == nil, "row 1's nil Date must round-trip as nil")
        #expect(decoded[2].scheduledAt?.timeIntervalSince1970 == rows[2].scheduledAt?.timeIntervalSince1970)
    }

    @Test("Phase 2C round-trip: a struct with a [String: String] field encodes as Map(String, String) then decodes back, preserving keys and values across rows")
    func mapStringStringRoundTrip() throws {
        struct LogRow: Codable, Equatable, Sendable {
            let id: UInt64
            let attributes: [String: String]
        }
        let rows: [LogRow] = [
            LogRow(id: 1, attributes: ["service": "api", "env": "prod", "region": "us-east-1"]),
            LogRow(id: 2, attributes: [:]),
            LogRow(id: 3, attributes: ["service": "worker", "env": "staging"]),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(LogRow.self, from: columns)
        #expect(decoded == rows, "Map round-trip must preserve keys and values per row")
    }

    @Test("Phase 2C: multiple Map fields in the same struct round-trip independently — keys+values stay paired with the right column")
    func multipleMapFieldsRoundTrip() throws {
        struct LogRow: Codable, Equatable, Sendable {
            let id: UInt64
            let resourceAttrs: [String: String]
            let scopeAttrs: [String: String]
        }
        let rows: [LogRow] = [
            LogRow(
                id: 1,
                resourceAttrs: ["service": "api"],
                scopeAttrs: ["scope": "auth"]
            ),
            LogRow(
                id: 2,
                resourceAttrs: ["service": "worker", "version": "1.2.3"],
                scopeAttrs: ["scope": "billing", "module": "invoices"]
            ),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(LogRow.self, from: columns)
        #expect(decoded == rows)
    }

    @Test("Phase 2D round-trip: a struct with a non-Optional UUID field encodes as UUID and decodes back, preserving the bytes across the round trip")
    func nonOptionalUUIDRoundTrip() throws {
        struct Row: Codable, Equatable, Sendable {
            let id: UUID
            let label: String
        }
        let rows: [Row] = [
            Row(id: UUID(), label: "alpha"),
            Row(id: UUID(), label: "beta"),
            Row(id: UUID(uuidString: "DEADBEEF-CAFE-BABE-1234-567890ABCDEF")!, label: "gamma"),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        #expect(decoded == rows, "UUID round-trip must preserve every byte")
    }

    @Test("Phase 2D round-trip: Optional<UUID> field with mixed nil/non-nil values produces a Nullable(UUID) column and decodes back preserving per-row presence")
    func optionalUUIDRoundTrip() throws {
        struct Row: Codable, Equatable, Sendable {
            let id: UInt64
            let externalId: UUID?
        }
        let rows: [Row] = [
            Row(id: 1, externalId: UUID()),
            Row(id: 2, externalId: nil),
            Row(id: 3, externalId: UUID()),
        ]
        let entries = try ClickHouseRowEncoder().encode(rows)
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        #expect(decoded == rows)
    }

    @Test("convertFromSnakeCase strategy: a Swift property `kinesisShardId` decodes from a column named `kinesis_shard_id`, matching JSONDecoder's well-known semantics")
    func convertFromSnakeCaseDecodes() throws {
        struct Row: Decodable, Equatable, Sendable {
            let kinesisShardId: String
            let recordIndex: UInt32
        }
        let columns = [
            ClickHouseSelectColumn(name: "kinesis_shard_id", typeName: "String", values: .string(["shard-1", "shard-2"])),
            ClickHouseSelectColumn(name: "record_index", typeName: "UInt32", values: .uint32([100, 200])),
        ]
        let decoded = try ClickHouseRowDecoder(keyDecodingStrategy: .convertFromSnakeCase)
            .decode(Row.self, from: columns)
        #expect(decoded == [
            Row(kinesisShardId: "shard-1", recordIndex: 100),
            Row(kinesisShardId: "shard-2", recordIndex: 200),
        ])
    }

    @Test("default useDefaultKeys strategy: a Swift property `kinesisShardId` requires a column named `kinesisShardId` exactly")
    func defaultStrategyUsesSwiftKeyVerbatim() throws {
        struct Row: Decodable, Sendable {
            let kinesisShardId: String
        }
        let columns = [
            ClickHouseSelectColumn(name: "kinesis_shard_id", typeName: "String", values: .string(["x"])),
        ]
        var thrown: Error?
        do {
            _ = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        } catch {
            thrown = error
        }
        let received = try #require(thrown,
            "default strategy must NOT silently match snake_case — the user opted out of conversion")
        if case ClickHouseError.codableDecodingFailure(let kind, _, _, _) = received {
            #expect(kind == .keyNotFound)
        } else {
            Issue.record("expected codableDecodingFailure(keyNotFound); got \(received)")
        }
    }

    @Test("convertToSnakeCase encoding + convertFromSnakeCase decoding round-trips a struct with mixed camelCase fields")
    func snakeCaseStrategyRoundTrip() throws {
        struct Row: Codable, Equatable, Sendable {
            let kinesisShardId: String
            let kinesisSequenceNumber: String
            let recordIndex: UInt32
            let serviceName: String
        }
        let rows: [Row] = [
            Row(kinesisShardId: "s-1", kinesisSequenceNumber: "100", recordIndex: 0, serviceName: "api"),
            Row(kinesisShardId: "s-2", kinesisSequenceNumber: "200", recordIndex: 1, serviceName: "worker"),
        ]
        let entries = try ClickHouseRowEncoder(keyEncodingStrategy: .convertToSnakeCase).encode(rows)
        // Verify the column names are snake_case after encode.
        let columnNames = entries.map(\.name).sorted()
        #expect(columnNames == [
            "kinesis_sequence_number", "kinesis_shard_id", "record_index", "service_name",
        ])
        let columns = entries.map {
            ClickHouseSelectColumn(name: $0.name, typeName: "<test>", values: $0.values)
        }
        let decoded = try ClickHouseRowDecoder(keyDecodingStrategy: .convertFromSnakeCase)
            .decode(Row.self, from: columns)
        #expect(decoded == rows)
    }

    @Test("decoder rejects Swift `Int` field with a typed unsupported-type error referencing platform-dependent width")
    func decodingSwiftIntIsRejected() throws {
        struct Row: Decodable, Sendable {
            let value: Int
        }
        let columns = [
            ClickHouseSelectColumn(name: "value", typeName: "Int64", values: .int64([42]))
        ]
        var thrown: Error?
        do {
            _ = try ClickHouseRowDecoder().decode(Row.self, from: columns)
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.rowEncoderUnsupportedType(let typeDesc, _, let message) = received {
            #expect(typeDesc == "Int")
            #expect(message.contains("platform-dependent"))
        } else {
            Issue.record("expected rowEncoderUnsupportedType for Int; got \(received)")
        }
    }

    @Test("decodeStreaming yields rows in document order and produces the same values as bulk decode")
    func streamingDecodeMatchesBulkDecode() throws {
        // Construct a 1000-row two-column block. Verify that
        // decodeStreaming yields each row in order with the same
        // values as the bulk decode would produce. This guards the
        // streaming-decode path used by `selectStream` against
        // regressions in row ordering or per-row state.
        struct Row: Decodable, Equatable {
            let id: Int64
            let name: String
        }
        let count = 1000
        let ids = (0..<count).map { Int64($0) }
        let names = (0..<count).map { "row-\($0)" }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "Int64", values: .int64(ids)),
            ClickHouseSelectColumn(name: "name", typeName: "String", values: .string(names))
        ]

        let decoder = ClickHouseRowDecoder()
        let bulk: [Row] = try decoder.decode(Row.self, from: columns)

        var streamed: [Row] = []
        try decoder.decodeStreaming(Row.self, from: columns) { row in
            streamed.append(row)
            return true
        }

        #expect(bulk == streamed, "streaming and bulk decode must produce identical rows")
        #expect(streamed.count == count)
        #expect(streamed.first == Row(id: 0, name: "row-0"))
        #expect(streamed.last == Row(id: 999, name: "row-999"))
    }

    @Test("decodeStreaming stops early when the body returns false (consumer-abandonment signal)")
    func streamingDecodeStopsOnFalseFromBody() throws {
        struct Row: Decodable, Equatable {
            let id: Int32
        }
        let columns = [
            ClickHouseSelectColumn(name: "id", typeName: "Int32", values: .int32([1, 2, 3, 4, 5]))
        ]

        var collected: [Row] = []
        try ClickHouseRowDecoder().decodeStreaming(Row.self, from: columns) { row in
            collected.append(row)
            // Stop after the third row.
            return collected.count < 3
        }
        #expect(collected.count == 3)
        #expect(collected == [Row(id: 1), Row(id: 2), Row(id: 3)])
    }

}
