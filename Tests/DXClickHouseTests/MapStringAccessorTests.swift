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

// Map(String, String) - tags, labels, attributes - is the most common map
// shape in production. ClickHouseMap exposed `stringKeys` but no matching
// way to read the values as strings, so a caller could see a map's keys but
// not its values, and had no dictionary view at all. The symmetric
// `stringValues` and a `stringDictionary` view (last value wins on a
// repeated key) close that gap, with `stringToString` for the insert side.
@Suite("ClickHouseMap exposes String values and a dictionary view")
struct MapStringAccessorTests {

    @Test("stringValues mirrors stringKeys for a String-to-String map")
    func valuesMirrorKeys() {
        let map = ClickHouseMap.stringToString([("env", "prod"), ("region", "us-east")])
        #expect(map.stringKeys == ["env", "region"])
        #expect(map.stringValues == ["prod", "us-east"])
    }

    @Test("stringDictionary zips keys and values into a Swift dictionary")
    func dictionaryView() {
        let map = ClickHouseMap.stringToString([("env", "prod"), ("region", "us-east")])
        #expect(map.stringDictionary == ["env": "prod", "region": "us-east"])
    }

    @Test("an empty map yields empty accessors")
    func emptyMap() {
        let map = ClickHouseMap.stringToString([])
        #expect(map.stringValues == [])
        #expect(map.stringDictionary == [:])
    }

    @Test("a repeated key keeps the last value in the dictionary view")
    func repeatedKeyLastWins() {
        let map = ClickHouseMap.stringToString([("k", "first"), ("k", "second")])
        #expect(map.stringValues == ["first", "second"])
        #expect(map.stringDictionary == ["k": "second"])
    }
}
