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
import Testing

// Fetching a nullable scalar — scalar(as: Int32?.self) for e.g.
// `SELECT max(x)` over a possibly-empty set — decodes through
// ScalarRowWrapper<Int32?>, which runs `container.decode(Optional<Int32>.self)`.
// The generic decode<T> previously rejected an Optional target as
// unsupported even though decodeIfPresent handles every nullable column.
// These structs reproduce that explicit-Optional decode and assert it now
// resolves to the value or nil. (A synthesized struct field uses
// decodeIfPresent and always worked; this is the explicit decode path.)
@Suite("Explicit Optional decode targets resolve via decodeIfPresent")
struct NullableScalarDecodeTests {

    private struct OptInt: Decodable {
        let value: Int32?
        enum CodingKeys: String, CodingKey { case value }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(Int32?.self, forKey: .value)
        }
    }

    private struct OptString: Decodable {
        let value: String?
        enum CodingKeys: String, CodingKey { case value }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(String?.self, forKey: .value)
        }
    }

    @Test("a present and an absent nullable Int32 both decode via explicit Optional")
    func optionalInt32() throws {
        let columns = [ClickHouseNamedColumn(name: "value", column: .nullableInt32([.present(7), .absent]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptInt.self, columns: columns, rowCount: 2)
        #expect(rows.count == 2)
        #expect(rows[0].value == 7)
        #expect(rows[1].value == nil)
    }

    @Test("an explicit Optional String decode resolves present and absent")
    func optionalString() throws {
        let columns = [ClickHouseNamedColumn(name: "value", column: .nullableString([.absent, .present(Array("hi".utf8))]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptString.self, columns: columns, rowCount: 2)
        #expect(rows.count == 2)
        #expect(rows[0].value == nil)
        #expect(rows[1].value == "hi")
    }

    @Test("an explicit Optional over a non-nullable column reads the value")
    func optionalOverNonNullable() throws {
        let columns = [ClickHouseNamedColumn(name: "value", column: .int32([42]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: OptInt.self, columns: columns, rowCount: 1)
        #expect(rows[0].value == 42)
    }
}
