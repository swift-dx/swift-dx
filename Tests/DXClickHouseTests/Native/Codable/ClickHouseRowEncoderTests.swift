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

@Suite("ClickHouseRowEncoder — primitive types")
struct ClickHouseRowEncoderTests {

    private struct PrimitivesRow: Encodable, Sendable {

        let id: UInt64
        let name: String
        let active: Bool
        let temperature: Double
        let count: Int32
        let tag: UInt8

    }

    @Test("a list of structs with String/UInt64/Bool/Double/Int32/UInt8 fields encodes to one ClickHouseColumnEntry per field, preserving row order and per-row values")
    func primitiveStructsEncodeToOneEntryPerField() throws {
        let rows: [PrimitivesRow] = [
            PrimitivesRow(id: 1, name: "alpha", active: true, temperature: 0.5, count: 10, tag: 200),
            PrimitivesRow(id: 2, name: "beta", active: false, temperature: -1.25, count: 20, tag: 100),
            PrimitivesRow(id: 3, name: "gamma", active: true, temperature: 99.99, count: 30, tag: 50),
        ]

        let entries = try ClickHouseRowEncoder().encode(rows)

        #expect(entries.count == 6, "one entry per field; got \(entries.count)")

        let columnsByName: [String: ClickHouseColumnEntry] = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.name, $0) }
        )

        let id = try #require(columnsByName["id"])
        guard case .uint64(let ids) = id.values else {
            Issue.record("id must materialize as .uint64; got \(id.values)")
            return
        }
        #expect(ids == [1, 2, 3])

        let name = try #require(columnsByName["name"])
        guard case .string(let names) = name.values else {
            Issue.record("name must materialize as .string; got \(name.values)")
            return
        }
        #expect(names == ["alpha", "beta", "gamma"])

        let active = try #require(columnsByName["active"])
        guard case .bool(let actives) = active.values else {
            Issue.record("active must materialize as .bool; got \(active.values)")
            return
        }
        #expect(actives == [true, false, true])

        let temp = try #require(columnsByName["temperature"])
        guard case .float64(let temps) = temp.values else {
            Issue.record("temperature must materialize as .float64; got \(temp.values)")
            return
        }
        #expect(temps == [0.5, -1.25, 99.99])

        let count = try #require(columnsByName["count"])
        guard case .int32(let counts) = count.values else {
            Issue.record("count must materialize as .int32; got \(count.values)")
            return
        }
        #expect(counts == [10, 20, 30])

        let tag = try #require(columnsByName["tag"])
        guard case .uint8(let tags) = tag.values else {
            Issue.record("tag must materialize as .uint8; got \(tag.values)")
            return
        }
        #expect(tags == [200, 100, 50])
    }

    @Test("encoding an empty array of rows produces an empty entries list — no schema is established")
    func emptyRowsProduceEmptyEntries() throws {
        let entries = try ClickHouseRowEncoder().encode([PrimitivesRow]())
        #expect(entries.isEmpty)
    }

    @Test("encoding a struct with a Swift `Int` field surfaces a typed unsupported-type error pointing at the platform-dependent width")
    func swiftIntIsRejectedAsPlatformDependent() throws {
        struct RowWithPlatformInt: Encodable, Sendable {
            let count: Int
        }
        var thrown: Error?
        do {
            _ = try ClickHouseRowEncoder().encode([RowWithPlatformInt(count: 42)])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.rowEncoderUnsupportedType(let typeDesc, let columnName, let message) = received {
            #expect(typeDesc == "Int")
            #expect(columnName == "count")
            #expect(message.contains("platform-dependent"))
        } else {
            Issue.record("expected rowEncoderUnsupportedType for Int; got \(received)")
        }
    }

    @Test("Phase 2: Optional<String> field with all-nil values produces a Nullable(String) column with two nil entries — no silent drop")
    func optionalNilAcrossAllRowsProducesNullableColumn() throws {
        struct RowWithOptional: Encodable, Sendable {
            let id: UInt64
            let name: String?
        }
        let entries = try ClickHouseRowEncoder().encode([
            RowWithOptional(id: 1, name: nil),
            RowWithOptional(id: 2, name: nil),
        ])
        #expect(entries.count == 2, "both columns must be captured; got \(entries.count)")
        let columnsByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let nameEntry = try #require(columnsByName["name"])
        guard case .nullableString(let nameValues) = nameEntry.values else {
            Issue.record("name should materialize as .nullableString; got \(nameEntry.values)")
            return
        }
        #expect(nameValues.map(\.value) == [nil, nil])
    }

    @Test("Phase 2: Optional<String> mixing nil and non-nil values across rows produces a Nullable(String) column preserving the per-row presence")
    func optionalMixedNilAndValueProducesNullableColumn() throws {
        struct RowWithOptional: Encodable, Sendable {
            let id: UInt64
            let name: String?
        }
        let entries = try ClickHouseRowEncoder().encode([
            RowWithOptional(id: 1, name: "first"),
            RowWithOptional(id: 2, name: nil),
            RowWithOptional(id: 3, name: "third"),
        ])
        let columnsByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let nameEntry = try #require(columnsByName["name"])
        guard case .nullableString(let nameValues) = nameEntry.values else {
            Issue.record("name should materialize as .nullableString; got \(nameEntry.values)")
            return
        }
        #expect(nameValues.map(\.value) == ["first", nil, "third"])
    }

    @Test("Phase 2: Optional<UInt64> field handles per-row presence the same way — nullable column emitted")
    func optionalUInt64MixedProducesNullableColumn() throws {
        struct RowWithOptional: Encodable, Sendable {
            let value: UInt64?
        }
        let entries = try ClickHouseRowEncoder().encode([
            RowWithOptional(value: 100),
            RowWithOptional(value: nil),
            RowWithOptional(value: 300),
        ])
        let entry = try #require(entries.first)
        guard case .nullableUInt64(let values) = entry.values else {
            Issue.record("value should materialize as .nullableUInt64; got \(entry.values)")
            return
        }
        #expect(values.map(\.value) == [100, nil, 300])
    }

    @Test("encoding a struct with a nested struct field surfaces a typed unsupported-type error")
    func nestedStructIsRejectedInPhase1() throws {
        struct Inner: Encodable, Sendable { let value: Int32 }
        struct Outer: Encodable, Sendable {
            let id: UInt64
            let inner: Inner
        }
        var thrown: Error?
        do {
            _ = try ClickHouseRowEncoder().encode([Outer(id: 1, inner: Inner(value: 42))])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.rowEncoderUnsupportedType = received {
            // Either column-route (encode<T:Encodable>) OR the nested
            // keyed container's reject path. Both are valid responses.
        } else {
            Issue.record("expected rowEncoderUnsupportedType for nested struct; got \(received)")
        }
    }

    @Test("type mismatch across rows surfaces rowEncoderColumnTypeMismatch identifying the offending column and row index")
    func typeMismatchAcrossRowsIsCaught() throws {
        // Use a custom Encodable that emits different types for the
        // same key across rows — the auto-generated Codable for a
        // homogeneous struct can't produce this mismatch, so we hand
        // craft an Encodable that does.
        struct RowA: Encodable, Sendable {
            let id: UInt64
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                try c.encode(id, forKey: .id)
            }
            enum K: String, CodingKey { case id }
        }
        struct RowB: Encodable, Sendable {
            let id: Int32
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                try c.encode(id, forKey: .id)
            }
            enum K: String, CodingKey { case id }
        }
        // Two-row INSERT with row-1 schema diverging from row-0.
        // The encoder accepts polymorphic input via [any Encodable]
        // — but our public encode() takes [T], so we use a tiny
        // wrapper Encodable that delegates to either RowA or RowB.
        struct Wrapper: Encodable, Sendable {
            let payload: any Encodable & Sendable
            func encode(to encoder: Encoder) throws {
                try payload.encode(to: encoder)
            }
        }
        var thrown: Error?
        do {
            _ = try ClickHouseRowEncoder().encode([
                Wrapper(payload: RowA(id: 1)),
                Wrapper(payload: RowB(id: 2)),
            ])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        if case ClickHouseError.rowEncoderColumnTypeMismatch(let columnName, _, _, let rowIndex) = received {
            #expect(columnName == "id")
            #expect(rowIndex == 1, "mismatch must be reported on row 1; got \(rowIndex)")
        } else {
            Issue.record("expected rowEncoderColumnTypeMismatch; got \(received)")
        }
    }

    @Test("field counts always equal row count after encoding — no off-by-one across all primitive fields")
    func fieldCountEqualsRowCount() throws {
        let rowCount = 100
        var rows: [PrimitivesRow] = []
        rows.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let id = UInt64(index)
            let name = "row-\(index)"
            let active = index % 2 == 0
            let temperature = Double(index) * 0.1
            let count = Int32(index)
            let tag = UInt8(index % 256)
            rows.append(PrimitivesRow(
                id: id, name: name, active: active,
                temperature: temperature, count: count, tag: tag
            ))
        }
        let entries = try ClickHouseRowEncoder().encode(rows)
        for entry in entries {
            let observedCount = Self.materializedCount(of: entry.values)
            #expect(observedCount == rowCount,
                    "column \(entry.name) materialized \(observedCount) values; expected \(rowCount)")
        }
    }

    private static func materializedCount(of values: ClickHouseColumnEntry.Values) -> Int {
        switch values {
        case .uint64(let v): return v.count
        case .uint32(let v): return v.count
        case .uint16(let v): return v.count
        case .uint8(let v): return v.count
        case .int64(let v): return v.count
        case .int32(let v): return v.count
        case .int16(let v): return v.count
        case .int8(let v): return v.count
        case .float64(let v): return v.count
        case .float32(let v): return v.count
        case .string(let v): return v.count
        case .bool(let v): return v.count
        default: return -1
        }
    }

    @Test("Optional<[String: String]> with a nil value surfaces a typed unsupported-type error instead of silently dropping the column. Pre-fix: the generic encodeIfPresent<T> fall-back returned with no append for nil, leaving the column unregistered and producing silent data loss (single-row case) or a misleading 'missing columns' error (multi-row case).")
    func optionalMapWithNilValueIsRejectedClearly() throws {
        struct Row: Encodable, Sendable {
            let id: UInt64
            let attributes: [String: String]?
        }
        var thrown: Error?
        do {
            _ = try ClickHouseRowEncoder().encode([Row(id: 1, attributes: nil)])
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "encoding Optional<[String: String]> with nil should throw, not silently drop the column")
        guard case ClickHouseError.rowEncoderUnsupportedType(_, let columnName, _) = received else {
            Issue.record("expected rowEncoderUnsupportedType; got \(received)")
            return
        }
        #expect(columnName == "attributes",
                "the error must point at the offending column so the user knows which field to fix; got \(columnName ?? "<nil>")")
    }

    @Test("Optional<NestedStruct> with a nil value surfaces a typed unsupported-type error rather than silently dropping the column. Symmetric concern to Optional<Map>: the generic encodeIfPresent<T> fall-back used to short-circuit on nil, so a single-row 'all-nil' input produced an empty entries list and a multi-row mixed input produced a 'missing columns' error one row late.")
    func optionalNestedStructWithNilValueIsRejectedClearly() throws {
        struct Inner: Encodable, Sendable { let value: Int32 }
        struct Row: Encodable, Sendable {
            let id: UInt64
            let payload: Inner?
        }
        var thrown: Error?
        do {
            _ = try ClickHouseRowEncoder().encode([Row(id: 1, payload: nil)])
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "encoding Optional<NestedStruct> with nil should throw")
        guard case ClickHouseError.rowEncoderUnsupportedType(_, let columnName, _) = received else {
            Issue.record("expected rowEncoderUnsupportedType; got \(received)")
            return
        }
        #expect(columnName == "payload")
    }

}
