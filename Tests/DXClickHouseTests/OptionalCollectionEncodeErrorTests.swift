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

// ClickHouse Array and Map columns are not nullable - they default to an
// empty collection, never NULL - so an optional collection field ([String]?,
// [String: Int64]?) has no column mapping. Encoding one used to fail with
// the misleading "Nested containers are not supported ... supported scalars"
// message, which wrongly implies [String] itself is unsupported. The error
// must instead state that collections are not nullable and point at the
// non-optional field.
@Suite("a present optional collection field fails with an actionable error")
struct OptionalCollectionEncodeErrorTests {

    private struct ArrayRow: Encodable {
        let tags: [String]?
    }

    private struct MapRow: Encodable {
        let labels: [String: Int64]?
    }

    private static func errorMessage<T: Encodable & Sendable>(_ row: T) -> String {
        do {
            _ = try ClickHouseRowEncoder().encode([row])
            return "<no error thrown>"
        } catch {
            return "\(error)"
        }
    }

    @Test("an optional array field names the not-nullable limitation")
    func optionalArray() {
        #expect(Self.errorMessage(ArrayRow(tags: ["a", "b"])).contains("not nullable"))
    }

    @Test("an optional map field names the not-nullable limitation")
    func optionalMap() {
        #expect(Self.errorMessage(MapRow(labels: ["x": 1])).contains("not nullable"))
    }
}
