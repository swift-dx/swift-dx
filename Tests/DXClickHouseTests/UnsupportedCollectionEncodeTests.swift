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

// A field whose value is a collection of an element type the encoder does
// not natively support must be rejected, whether the collection is empty or
// not. A non-empty one already failed when its first element hit the row's
// container, but an empty one encoded nothing and was silently dropped —
// leaving the produced row one column short, which corrupts the INSERT
// (column misalignment) rather than failing loudly. Both cases must throw.
@Suite("an unsupported collection field is rejected, empty or not")
struct UnsupportedCollectionEncodeTests {

    private struct Point: Codable, Sendable { let x: Int32 }
    private struct Row: Codable, Sendable { let points: [Point] }

    @Test("an empty array of an unsupported element type is rejected, not silently dropped")
    func emptyUnsupportedArrayRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(points: [])])
        }
    }

    @Test("a non-empty array of an unsupported element type is rejected")
    func nonEmptyUnsupportedArrayRejected() {
        #expect(throws: ClickHouseError.self) {
            _ = try ClickHouseRowEncoder().encode([Row(points: [Point(x: 1)])])
        }
    }
}
