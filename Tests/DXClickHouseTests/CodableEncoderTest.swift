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

@Suite("DXClickHouse Codable encoder")
struct ClickHouseRowEncoderTest {

    struct PlainRow: Codable, Sendable {
        let id: UInt64
        let name: String
        let score: Double
    }

    struct OptionalRow: Codable, Sendable {
        let id: UInt64
        let label: String?
        let count: Int32?
    }

    struct AllScalarsRow: Codable, Sendable {
        let s: String
        let b: Bool
        let i8: Int8
        let i16: Int16
        let i32: Int32
        let i64: Int64
        let u8: UInt8
        let u16: UInt16
        let u32: UInt32
        let u64: UInt64
        let f: Float
        let d: Double
    }

    @Test("Encoder produces one typed column per Swift field, preserving the declaration order")
    func encodesColumnsInDeclarationOrder() throws {
        let encoder = ClickHouseRowEncoder()
        let columns = try encoder.encode([
            PlainRow(id: 1, name: "alpha", score: 1.5),
            PlainRow(id: 2, name: "beta", score: 2.5),
        ])
        #expect(columns.count == 3)
        #expect(columns[0].name == "id")
        #expect(columns[1].name == "name")
        #expect(columns[2].name == "score")
        switch columns[0].column {
        case .uint64(let values): #expect(values == [1, 2])
        default: Issue.record("expected uint64 column")
        }
        switch columns[1].column {
        case .stringValues(let values): #expect(values == ["alpha", "beta"])
        default: Issue.record("expected string column")
        }
        switch columns[2].column {
        case .float64(let values): #expect(values == [1.5, 2.5])
        default: Issue.record("expected float64 column")
        }
    }

    @Test("Encoder lowers Optional<T> to Nullable(T) and preserves absent rows")
    func encodesNullableColumns() throws {
        let encoder = ClickHouseRowEncoder()
        let columns = try encoder.encode([
            OptionalRow(id: 1, label: "first", count: 7),
            OptionalRow(id: 2, label: nil, count: nil),
        ])
        #expect(columns.count == 3)
        switch columns[1].column {
        case .nullableString(let values):
            switch values[0] {
            case .present(let v): #expect(String(decoding: v, as: UTF8.self) == "first")
            case .absent: Issue.record("row 0 should be present")
            }
            #expect(values[1].isAbsent)
        default: Issue.record("expected nullableString column for label")
        }
        switch columns[2].column {
        case .nullableInt32(let values):
            switch values[0] {
            case .present(let v): #expect(v == 7)
            case .absent: Issue.record("row 0 should be present")
            }
            #expect(values[1].isAbsent)
        default: Issue.record("expected nullableInt32 column for count")
        }
    }

    @Test("Encoder rejects rows that introduce a new column after row 0 has finished")
    func rejectsLateColumnIntroduction() throws {
        // Heterogeneous-row test: a struct whose `encode(to:)` picks
        // the column name from a stored field, so two instances can
        // produce different column sets without the static type
        // changing.
        struct DynamicRow: Codable, Sendable {
            let key: String
            let value: Int32

            init(key: String, value: Int32) { self.key = key; self.value = value }

            init(from decoder: Decoder) throws {
                self.key = ""; self.value = 0
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: AnyKey.self)
                try container.encode(value, forKey: AnyKey(key))
            }
        }
        let rows = [
            DynamicRow(key: "x", value: 1),
            DynamicRow(key: "y", value: 2),
        ]
        let caught = captureEncoderError {
            _ = try ClickHouseRowEncoder().encode(rows)
        }
        switch caught {
        case .some(let error):
            switch error {
            case .protocolError: break
            default: Issue.record("expected protocolError, got \(error)")
            }
        case .none:
            Issue.record("expected encoder to reject row 1 with column 'y'")
        }
    }

    @Test("Encoder rejects Swift Int (platform-dependent width)")
    func rejectsPlatformInt() throws {
        struct R: Codable, Sendable { let x: Int }
        let caught = captureEncoderError {
            _ = try ClickHouseRowEncoder().encode([R(x: 42)])
        }
        switch caught {
        case .some(let error):
            switch error {
            case .protocolError(_, let message):
                #expect(message.contains("Int"))
            default:
                Issue.record("expected protocolError, got \(error)")
            }
        case .none:
            Issue.record("expected encoder to reject Swift Int")
        }
    }

    // Encoder throws are typed, but Swift's `catch let x as T` against
    // an already-typed throw triggers a SILGen ICE in 6.3.2. Capture the
    // typed throw into a Result wrapper to defeat the redundant cast.
    private func captureEncoderError(_ body: () throws -> Void) -> ClickHouseError? {
        do {
            try body()
            return nil
        } catch let error as ClickHouseError {
            return error
        } catch {
            return nil
        }
    }

    @Test("Encoder handles every scalar overload exactly once")
    func encodesAllScalarOverloads() throws {
        let row = AllScalarsRow(
            s: "x", b: true,
            i8: -1, i16: -2, i32: -3, i64: -4,
            u8: 1, u16: 2, u32: 3, u64: 4,
            f: 1.5, d: 2.5
        )
        let encoder = ClickHouseRowEncoder()
        let columns = try encoder.encode([row])
        #expect(columns.count == 12)
        // Verify every column has exactly one row of the right type.
        for column in columns { #expect(column.column.rowCount == 1) }
    }

    @Test("Encoder produces empty column array for empty input")
    func emptyInput() throws {
        struct R: Codable, Sendable { let x: Int32 }
        let encoder = ClickHouseRowEncoder()
        let columns = try encoder.encode([R]())
        #expect(columns.isEmpty)
    }
}

// Used by `rejectsLateColumnIntroduction` to drive two heterogeneous
// row shapes through the same encoder pass — the runtime-synthesised
// CodingKeys for each Codable struct would otherwise produce a
// statically-typed but homogeneous input array.
struct AnyKey: CodingKey {

    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
