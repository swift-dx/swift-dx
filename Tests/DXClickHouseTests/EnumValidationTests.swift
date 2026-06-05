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

// ClickHouseEnum8/Enum16 document that the encoder verifies the row's
// ordinal appears in the mapping (and, for Enum8, that every mapping
// ordinal fits Int8). Without that check an out-of-mapping value is sent
// to the server, which rejects the whole INSERT with an opaque Enum error
// instead of a clear, column-named client-side failure.
@Suite("Enum encoder validates the ordinal against the mapping")
struct EnumValidationTests {

    static let status: [ClickHouseEnumPair] = [
        ClickHouseEnumPair(name: "active", value: 1),
        ClickHouseEnumPair(name: "closed", value: 2),
    ]

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

    @Test("an Enum8 ordinal absent from the mapping is rejected")
    func enum8OutOfMappingRejected() {
        let outcome = Self.encode(Enum8Row(status: ClickHouseEnum8(value: 9, mapping: Self.status)))
        #expect(outcome == .rejected(stage: "encoder.enum"))
    }

    @Test("an in-mapping Enum8 ordinal still encodes")
    func enum8InMappingEncodes() {
        let outcome = Self.encode(Enum8Row(status: ClickHouseEnum8(value: 2, mapping: Self.status)))
        #expect(outcome == .encoded)
    }

    @Test("an Enum16 ordinal absent from the mapping is rejected")
    func enum16OutOfMappingRejected() {
        let mapping = [ClickHouseEnumPair(name: "a", value: 1), ClickHouseEnumPair(name: "big", value: 300)]
        let outcome = Self.encode(Enum16Row(code: ClickHouseEnum16(value: 7, mapping: mapping)))
        #expect(outcome == .rejected(stage: "encoder.enum"))
    }

    @Test("an Enum8 mapping ordinal that does not fit Int8 is rejected")
    func enum8MappingOrdinalTooWideRejected() {
        let mapping = [ClickHouseEnumPair(name: "a", value: 1), ClickHouseEnumPair(name: "wide", value: 200)]
        let outcome = Self.encode(Enum8Row(status: ClickHouseEnum8(value: 1, mapping: mapping)))
        #expect(outcome == .rejected(stage: "encoder.enum"))
    }
}
