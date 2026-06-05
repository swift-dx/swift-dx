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

// The connection's Map key/value splitter (used when skipping Map columns
// on the wire) must, like the Tuple splitter, treat brackets and commas
// inside an Enum's quoted member names as literal text. Otherwise a valid
// Map(Enum8('x(' = 1), V) column desyncs the column-skip walk.
@Suite("Map inner-type splitter is quote-aware")
struct MapInnerSplitTests {

    @Test("a plain Map splits key and value on the top-level comma")
    func plainMapSplits() {
        let (key, value) = ClickHouseConnection.splitMapInner("String, UInt64")
        #expect(key == "String")
        #expect(value == "UInt64")
    }

    @Test("a nested Tuple value keeps its inner comma")
    func nestedTupleValue() {
        let (key, value) = ClickHouseConnection.splitMapInner("String, Tuple(a UInt64, b String)")
        #expect(key == "String")
        #expect(value == "Tuple(a UInt64, b String)")
    }

    @Test("an Enum key with an unbalanced bracket in a member name still splits")
    func enumKeyWithUnbalancedBracket() {
        let (key, value) = ClickHouseConnection.splitMapInner("Enum8('a(' = 1, 'b' = 2), String")
        #expect(key == "Enum8('a(' = 1, 'b' = 2)")
        #expect(value == "String")
    }
}
