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

// ClickHouseGeoTypeName.expand runs on every column type name at the
// header boundary, before the Tuple/Map splitters see it. It splits
// composite type arguments on top-level commas/spaces, so it must also be
// quote-aware: an Enum member name carrying a bracket (e.g. 'a(') must not
// be misread as structure, or the whole column type is corrupted before
// decoding even begins.
@Suite("Geo type-name expansion is quote-aware")
struct GeoExpandQuoteTests {

    @Test("a Geo alias still expands to its structural type")
    func pointExpands() {
        #expect(ClickHouseGeoTypeName.expand("Point") == "Tuple(Float64, Float64)")
    }

    @Test("a normal Tuple with an Enum round-trips unchanged")
    func tupleWithPlainEnumUnchanged() {
        let type = "Tuple(Enum8('active' = 1, 'idle' = 2), UInt64)"
        #expect(ClickHouseGeoTypeName.expand(type) == type)
    }

    @Test("an Enum member name with an unbalanced bracket is not corrupted")
    func tupleWithBracketEnumUnchanged() {
        let type = "Tuple(status Enum8('a(' = 1, 'b' = 2), value UInt64)"
        #expect(ClickHouseGeoTypeName.expand(type) == type)
    }
}
