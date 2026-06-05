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
import Testing

// ClickHouse requires every Enum name AND every Enum ordinal to be unique
// within the type; `Enum8('a' = 1, 'a' = 2)` and `Enum8('a' = 1, 'b' = 1)`
// are both rejected by the server. The encoder already rejects empty
// mappings, empty/comma names, and out-of-mapping ordinals, but a duplicate
// name or value slipped through and surfaced only as an opaque server-side
// INSERT failure. These cases pin the boundary check.
@Suite("Enum encoder rejects duplicate names and ordinals")
struct EnumMappingUniquenessTests {

    struct Enum8Row: Codable, Sendable { let status: ClickHouseEnum8 }
    struct Enum16Row: Codable, Sendable { let code: ClickHouseEnum16 }

    private enum Outcome: Sendable, Equatable {
        case encoded
        case rejected(stage: String)
        case otherError(String)
    }

    private static func encode<T: Encodable & Sendable>(_ row: T) -> Outcome {
        do {
            _ = try ClickHouseRowEncoder().encode([row])
            return .encoded
        } catch let error {
            if case .protocolError(let stage, _) = error { return .rejected(stage: stage) }
            return .otherError(String(describing: error))
        }
    }

    @Test("a duplicate Enum8 name is rejected")
    func enum8DuplicateNameRejected() {
        let mapping = [ClickHouseEnumPair(name: "active", value: 1), ClickHouseEnumPair(name: "active", value: 2)]
        let outcome = Self.encode(Enum8Row(status: ClickHouseEnum8(value: 1, mapping: mapping)))
        #expect(outcome == .rejected(stage: "encoder.enum"))
    }

    @Test("a duplicate Enum8 ordinal is rejected")
    func enum8DuplicateValueRejected() {
        let mapping = [ClickHouseEnumPair(name: "active", value: 1), ClickHouseEnumPair(name: "closed", value: 1)]
        let outcome = Self.encode(Enum8Row(status: ClickHouseEnum8(value: 1, mapping: mapping)))
        #expect(outcome == .rejected(stage: "encoder.enum"))
    }

    @Test("a duplicate Enum16 name is rejected")
    func enum16DuplicateNameRejected() {
        let mapping = [ClickHouseEnumPair(name: "a", value: 1), ClickHouseEnumPair(name: "a", value: 300)]
        let outcome = Self.encode(Enum16Row(code: ClickHouseEnum16(value: 1, mapping: mapping)))
        #expect(outcome == .rejected(stage: "encoder.enum"))
    }

    @Test("a duplicate Enum16 ordinal is rejected")
    func enum16DuplicateValueRejected() {
        let mapping = [ClickHouseEnumPair(name: "a", value: 300), ClickHouseEnumPair(name: "b", value: 300)]
        let outcome = Self.encode(Enum16Row(code: ClickHouseEnum16(value: 300, mapping: mapping)))
        #expect(outcome == .rejected(stage: "encoder.enum"))
    }

    @Test("a mapping with unique names and ordinals still encodes")
    func uniqueMappingEncodes() {
        let mapping = [ClickHouseEnumPair(name: "active", value: 1), ClickHouseEnumPair(name: "closed", value: 2)]
        let outcome = Self.encode(Enum8Row(status: ClickHouseEnum8(value: 2, mapping: mapping)))
        #expect(outcome == .encoded)
    }
}
