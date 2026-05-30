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

@Suite("ClickHouse column spec — typeName round-trip")
struct ClickHouseColumnSpecTypeNameTests {

    @Test(
        "every constructible spec round-trips through typeName and the parser",
        arguments: [
            ClickHouseColumnSpec.int8, .int16, .int32, .int64,
            .uint8, .uint16, .uint32, .uint64,
            .float32, .float64,
            .string, .fixedString(length: 16),
            .bool, .uuid,
            .date, .date32,
            .dateTime(timezone: .serverDefault), .dateTime(timezone: .explicit("UTC")),
            .dateTime64(precision: 3, timezone: .serverDefault),
            .dateTime64(precision: 9, timezone: .explicit("Pacific/Auckland")),
            .ipv4, .ipv6,
            .array(of: .int32),
            .array(of: .nullable(of: .string)),
            .nullable(of: .uuid),
            .tuple(elements: [.int32, .string, .bool]),
            .map(key: .string, value: .int64),
            .map(key: .string, value: .array(of: .nullable(of: .string))),
        ]
    )
    func roundTripEverySpec(_ spec: ClickHouseColumnSpec) throws {
        let parsed = try ClickHouseTypeNameParser.parse(spec.typeName)
        #expect(parsed == spec)
    }

    @Test("DateTime without timezone serializes to bare DateTime")
    func dateTimeBareForm() {
        #expect(ClickHouseColumnSpec.dateTime(timezone: .serverDefault).typeName == "DateTime")
    }

    @Test("DateTime64 without timezone omits the second argument")
    func dateTime64SingleArg() {
        #expect(ClickHouseColumnSpec.dateTime64(precision: 3, timezone: .serverDefault).typeName == "DateTime64(3)")
    }

    @Test("Tuple separator is comma-space, matching CH's wire convention")
    func tupleSeparatorIsCommaSpace() {
        let typeName = ClickHouseColumnSpec.tuple(elements: [.int32, .string]).typeName
        #expect(typeName == "Tuple(Int32, String)")
    }

    @Test("apostrophe in timezone is escaped as doubled-quote")
    func apostropheEscapedInTimezone() throws {
        let original: ClickHouseColumnSpec = .dateTime(timezone: .explicit("weird'name"))
        #expect(original.typeName == "DateTime('weird''name')")
        let parsed = try ClickHouseTypeNameParser.parse(original.typeName)
        #expect(parsed == original)
    }

    @Test("deeply nested spec round-trips through typeName and parser")
    func deeplyNestedRoundTrip() throws {
        let original: ClickHouseColumnSpec = .map(
            key: .string,
            value: .array(of: .nullable(of: .tuple(elements: [.int64, .ipv4, .uuid])))
        )
        let parsed = try ClickHouseTypeNameParser.parse(original.typeName)
        #expect(parsed == original)
    }

}
