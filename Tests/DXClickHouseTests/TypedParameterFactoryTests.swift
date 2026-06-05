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

// Pins the field-dump string each typed factory emits without needing a live
// server. The integration suite proves the server reconstructs these dumps; this
// suite is the fast guard that the encoding itself does not drift — a regression
// in the two-pass escaping would change these literals and fail here first.
@Suite("typed query-parameter factories emit the expected field dump")
struct TypedParameterFactoryTests {

    @Test("numeric factories wrap the decimal text in single quotes")
    func numericDumps() {
        #expect(ClickHouseQueryParameter.uint64(name: "a", value: 0).value == "'0'")
        #expect(ClickHouseQueryParameter.uint64(name: "a", value: .max).value == "'18446744073709551615'")
        #expect(ClickHouseQueryParameter.int64(name: "a", value: -1).value == "'-1'")
        #expect(ClickHouseQueryParameter.int64(name: "a", value: .min).value == "'-9223372036854775808'")
        #expect(ClickHouseQueryParameter.int(name: "a", value: -42).value == "'-42'")
        #expect(ClickHouseQueryParameter.double(name: "a", value: 3.5).value == "'3.5'")
    }

    @Test("bool factory emits the lowercase keyword the server parses")
    func boolDumps() {
        #expect(ClickHouseQueryParameter.bool(name: "a", value: true).value == "'true'")
        #expect(ClickHouseQueryParameter.bool(name: "a", value: false).value == "'false'")
    }

    @Test("dateTime factory emits quoted epoch seconds, truncating sub-second precision")
    func dateTimeDumps() {
        #expect(ClickHouseQueryParameter.dateTime(name: "a", value: Date(timeIntervalSince1970: 1_736_948_730)).value == "'1736948730'")
        #expect(ClickHouseQueryParameter.dateTime(name: "a", value: Date(timeIntervalSince1970: 1_736_948_730.987)).value == "'1736948730'")
    }

    @Test("uuid factory emits the canonical lowercase form in single quotes")
    func uuidDumps() {
        let value = UUID(uuid: (0x61, 0xF0, 0xC4, 0x04, 0x5C, 0xB3, 0x11, 0xE7, 0x90, 0x7B, 0xA6, 0x00, 0x6A, 0xD3, 0xDB, 0xA0))
        #expect(ClickHouseQueryParameter.uuid(name: "a", value: value).value == "'61f0c404-5cb3-11e7-907b-a6006ad3dba0'")
    }

    @Test("string factory escapes for both decode passes")
    func stringDumps() {
        #expect(ClickHouseQueryParameter.string(name: "a", value: "plain").value == "'plain'")
        #expect(ClickHouseQueryParameter.string(name: "a", value: "o'hara").value == "'o\\'hara'")
        #expect(ClickHouseQueryParameter.string(name: "a", value: "\\").value == "'\\\\\\\\'")
        #expect(ClickHouseQueryParameter.string(name: "a", value: "a\tb").value == "'a\\\\tb'")
    }

    @Test("every factory preserves the parameter name verbatim")
    func namePreserved() {
        #expect(ClickHouseQueryParameter.uint64(name: "user_id", value: 1).name == "user_id")
        #expect(ClickHouseQueryParameter.bool(name: "active", value: true).name == "active")
        #expect(ClickHouseQueryParameter.string(name: "label", value: "x").name == "label")
    }
}
