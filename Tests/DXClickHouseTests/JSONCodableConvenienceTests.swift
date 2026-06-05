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

// A JSON-payload column round-trips a Swift Codable value. Without these
// conveniences a caller had to reach for Foundation directly -
// JSONEncoder().encode(value) -> bytes on the way in and
// JSONDecoder().decode(_:from: Data(json.bytes)) on the way out - which is
// boilerplate and leaks an untyped Foundation error. ClickHouseJSON should
// encode from and decode to any Codable value with a typed throw.
@Suite("ClickHouseJSON round-trips a Swift Codable value")
struct JSONCodableConvenienceTests {

    private struct Payload: Codable, Equatable {
        let id: Int
        let tags: [String]
        let active: Bool
    }

    @Test("encoding then decoding a value reproduces it")
    func roundTrip() throws {
        let payload = Payload(id: 42, tags: ["alpha", "beta"], active: true)
        let json = try ClickHouseJSON(encoding: payload)
        let decoded = try json.decode(Payload.self)
        #expect(decoded == payload)
    }

    @Test("the encoded text is valid JSON the text accessor exposes")
    func encodesToJSONText() throws {
        let json = try ClickHouseJSON(encoding: ["k": 1])
        #expect(json.text == "{\"k\":1}")
    }

    @Test("decoding malformed JSON throws a typed ClickHouseError")
    func malformedDecodeThrows() {
        let json = ClickHouseJSON("this is not json")
        #expect(throws: ClickHouseError.self) {
            _ = try json.decode(Payload.self)
        }
    }
}
