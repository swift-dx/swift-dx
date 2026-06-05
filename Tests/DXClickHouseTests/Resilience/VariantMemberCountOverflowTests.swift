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

// A Variant column's per-row discriminator is a single byte, so the wire
// format admits at most 255 members (0-254 select a member, 255 is NULL).
// The typed decoder walks every declared member and narrows the member
// index to UInt8 to match it against the discriminators. A server-supplied
// type name declaring 256 or more members drives that index to 256, where
// the UInt8 narrowing traps and crashes the client. The decoder must
// reject an over-count member list as malformed instead.
@Suite("Variant decode rejects a member count past the one-byte discriminator limit")
struct VariantMemberCountOverflowTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func variantTypeName(memberCount: Int) -> String {
        let members = Array(repeating: "UInt8", count: memberCount).joined(separator: ", ")
        return "Variant(\(members))"
    }

    @Test("a Variant with 257 members is rejected, not trapped on the UInt8 member index")
    func rejectsOverCountVariant() throws {
        // Body: 8-byte basic-mode prefix, one discriminator (0 -> member 0),
        // then member 0's single UInt8 value. Members 1...256 match no row.
        let body = Self.uint64LE(0) + [0x00] + [0x00]
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["value"],
            columnTypes: [Self.variantTypeName(memberCount: 257)],
            bodyStart: 0, bodyLength: body.count
        )

        var stage = "none"
        do {
            _ = try body.withUnsafeBytes { raw in
                try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
            }
        } catch let error as ClickHouseError {
            if case .protocolError(let parsed, _) = error { stage = parsed }
        }

        #expect(stage == "decoder.variant")
    }
}
