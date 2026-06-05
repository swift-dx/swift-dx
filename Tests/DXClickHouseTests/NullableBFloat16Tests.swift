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

// Every wrapper column kind that ClickHouse allows inside Nullable(T) is
// reachable from a Swift Optional field of the matching wrapper type —
// except BFloat16, which the encoder's Optional dispatch omitted, so a
// `ClickHouseBFloat16?` field threw "unsupported Optional" on a null row
// while ClickHouseIPv4?, ClickHouseDecimal?, etc. all worked. This pins
// the parity.
@Suite("Nullable(BFloat16) encodes from a ClickHouseBFloat16? field")
struct NullableBFloat16Tests {

    struct Row: Codable, Sendable, Equatable { let v: ClickHouseBFloat16? }

    @Test("a ClickHouseBFloat16? field lowers to a Nullable(BFloat16) column")
    func encodesNullableBFloat16() throws {
        let rows = [
            Row(v: ClickHouseBFloat16(rawBits: 0x3F80)),
            Row(v: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        #expect(columns[0].column.typeName == "Nullable(BFloat16)")
        guard case .nullable(let mask, let inner) = columns[0].column else {
            Issue.record("expected a nullable column, got \(columns[0].column.typeName)")
            return
        }
        #expect(mask == [false, true])
        guard case .bfloat16(let values) = inner else {
            Issue.record("expected a bfloat16 inner column, got \(inner.typeName)")
            return
        }
        #expect(values == [0x3F80, 0])
    }

    @Test("Nullable(BFloat16) round-trips a present value and a null through the decoder")
    func roundTripsNullableBFloat16() throws {
        let rows = [
            Row(v: ClickHouseBFloat16(rawBits: 0x3F80)),
            Row(v: nil),
        ]
        let columns = try ClickHouseRowEncoder().encode(rows)
        let decoded = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 2)
        #expect(decoded == rows)
    }
}
