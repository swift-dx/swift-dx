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

import Testing
@testable import DXCore

@Suite
struct JSONValueTests {

    @Test
    func objectEqualityIgnoresMemberOrder() {
        let first = JSONFixtures.object([("a", .bool(true)), ("b", .null)])
        let second = JSONFixtures.object([("b", .null), ("a", .bool(true))])
        #expect(first == second)
    }

    @Test
    func objectInequalityOnDifferentValue() {
        let first = JSONFixtures.object([("a", .bool(true))])
        let second = JSONFixtures.object([("a", .bool(false))])
        #expect(first != second)
    }

    @Test
    func objectInequalityOnDifferentKeys() {
        let first = JSONFixtures.object([("a", .null)])
        let second = JSONFixtures.object([("b", .null)])
        #expect(first != second)
    }

    @Test
    func arrayEqualityIsOrderSensitive() {
        let first = JSONFixtures.array([JSONFixtures.signedInteger(1), JSONFixtures.signedInteger(2)])
        let second = JSONFixtures.array([JSONFixtures.signedInteger(2), JSONFixtures.signedInteger(1)])
        #expect(first != second)
    }

    @Test
    func orderInsensitiveObjectsHashEqually() {
        let first = JSONFixtures.object([("a", .bool(true)), ("b", .null)])
        let second = JSONFixtures.object([("b", .null), ("a", .bool(true))])
        let set: Set<JSONValue> = [first, second]
        #expect(set.count == 1)
    }

    @Test
    func distinctValuesHashIntoSeparateSlots() {
        let set: Set<JSONValue> = [.bool(true), .bool(false), .null, .string("x")]
        #expect(set.count == 4)
    }

    @Test
    func lookupFindsPresentKey() {
        let object = JSONObject(members: [JSONObject.Member(key: "id", value: JSONFixtures.signedInteger(9))])
        #expect(object.lookup("id") == .found(JSONFixtures.signedInteger(9)))
    }

    @Test
    func lookupReportsMissingKey() {
        let object = JSONObject(members: [])
        #expect(object.lookup("absent") == .notFound)
    }

    @Test
    func containsReflectsMembership() {
        let object = JSONObject(members: [JSONObject.Member(key: "id", value: .null)])
        #expect(object.contains("id"))
        #expect(!object.contains("other"))
    }

    @Test
    func keysListsMemberNames() {
        let object = JSONObject(members: [
            JSONObject.Member(key: "a", value: .null),
            JSONObject.Member(key: "b", value: .null),
        ])
        #expect(object.keys == ["a", "b"])
    }

    @Test
    func numberEqualityAcrossSignedAndUnsigned() {
        let signed = JSONNumber(form: .signedInteger(5))
        let unsigned = JSONNumber(form: .unsignedInteger(5))
        #expect(signed == unsigned)
    }
}
