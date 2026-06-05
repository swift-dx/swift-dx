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

// A Decimal(P, S) column stores its unscaled value in a fixed byte width
// chosen from P (P<=9 -> 4 bytes, P<=18 -> 8, P<=38 -> 16, P<=76 -> 32).
// The wire writer wrote only that many low bytes, so a ClickHouseDecimal
// whose value exceeded the precision was silently truncated on insert -
// corrupt data, the worst failure mode. As the block writer already rejects
// over-length FixedString and out-of-range DateTime, an over-range Decimal
// must be rejected, not truncated.
@Suite("an over-range Decimal value is rejected, not silently truncated")
struct DecimalOverRangeRejectionTests {

    private struct Row: Encodable {
        let price: ClickHouseDecimal
    }

    // Constraint validation runs when the columns are serialized to the
    // wire (encodeDataPacket), not when the encoder merely builds them.
    private static func encodeToWire(_ row: Row) throws {
        let columns = try ClickHouseRowEncoder().encode([row])
        _ = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseQueryBuilder.revision)
    }

    @Test("a value that fits the declared precision encodes")
    func inRangeEncodes() throws {
        try Self.encodeToWire(Row(price: ClickHouseDecimal(unscaled: 123_456, precision: 9, scale: 2)))
    }

    @Test("a negative value that fits the declared precision encodes")
    func negativeInRangeEncodes() throws {
        try Self.encodeToWire(Row(price: ClickHouseDecimal(unscaled: -987_654, precision: 9, scale: 2)))
    }

    @Test("a positive value beyond Decimal32 range is rejected")
    func positiveOverRangeRejected() {
        #expect(throws: ClickHouseError.self) {
            try Self.encodeToWire(Row(price: ClickHouseDecimal(unscaled: 10_000_000_000, precision: 9, scale: 0)))
        }
    }

    @Test("a negative value beyond Decimal32 range is rejected")
    func negativeOverRangeRejected() {
        #expect(throws: ClickHouseError.self) {
            try Self.encodeToWire(Row(price: ClickHouseDecimal(unscaled: -10_000_000_000, precision: 9, scale: 0)))
        }
    }

    @Test("a value beyond Decimal64 range is rejected")
    func overDecimal64Rejected() {
        // limb1 set => the value needs more than 8 bytes, exceeding Decimal64.
        let value = ClickHouseDecimal(limb0: 0, limb1: 1, limb2: 0, limb3: 0, precision: 18, scale: 0)
        #expect(throws: ClickHouseError.self) {
            try Self.encodeToWire(Row(price: value))
        }
    }
}
