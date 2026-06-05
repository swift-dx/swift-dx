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

// Array(UUID) decodes natively into [UUID], but inserting a [UUID] field was
// impossible: there was no clean encode path. UUID stores its two 8-byte
// halves little-endian and a UUID column type is "UUID", so neither the
// FixedString(16) raw-bytes shape nor a manual ClickHouseArray could produce
// a correctly-typed, correctly-ordered Array(UUID). A first-class UUID
// element type makes [UUID] insert symmetrically with how it selects.
@Suite("[UUID] arrays insert symmetrically with how they select")
struct UUIDArrayEncodeTests {

    private struct Row: Codable, Sendable, Equatable {
        let ids: [UUID]
    }

    @Test("a [UUID] field round-trips through encode then decode")
    func roundTrips() throws {
        let a = UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
        let b = UUID(uuid: (16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31))
        let original = [Row(ids: [a, b])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(UUID)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }

    @Test("an empty [UUID] encodes as an empty Array(UUID)")
    func emptyArrayEncodes() throws {
        let original = [Row(ids: [])]
        let columns = try ClickHouseRowEncoder().encode(original)
        #expect(columns[0].column.typeName == "Array(UUID)")
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(decoded == original)
    }
}
