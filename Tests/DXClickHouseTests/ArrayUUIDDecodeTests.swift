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

// Array(UUID) is a common shape (a row's set of related entity identifiers).
// On the wire it is laid out exactly like Array(FixedString(16)): cumulative
// per-row offsets followed by the flattened 16-byte elements. The decoder
// rejected the UUID element type, so selecting such a column failed. UUID
// stores its two 8-byte halves little-endian, so each element's halves are
// reversed to recover the text-form byte order, matching the scalar path.
@Suite("DXClickHouse Array(UUID) decode")
struct ArrayUUIDDecodeTests {

    struct Row: Codable, Sendable, Equatable {
        let ids: [UUID]
    }

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    // The wire form of a UUID: each 8-byte half reversed relative to the
    // text-form bytes.
    private static func wire(_ textBytes: [UInt8]) -> [UInt8] {
        Array(textBytes[0..<8].reversed()) + Array(textBytes[8..<16].reversed())
    }

    private static func uuid(_ textBytes: [UInt8]) -> UUID {
        textBytes.withUnsafeBytes { raw in
            UUID(uuid: raw.load(as: uuid_t.self))
        }
    }

    @Test("a row's Array(UUID) decodes its elements with half-swapped byte order")
    func decodesArrayOfUUID() throws {
        let aBytes: [UInt8] = (0..<16).map { UInt8($0) }
        let bBytes: [UInt8] = (16..<32).map { UInt8($0) }
        let body = Self.uint64LE(2) + Self.wire(aBytes) + Self.wire(bBytes)
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["ids"],
            columnTypes: ["Array(UUID)"],
            bodyStart: 0, bodyLength: body.count
        )
        let columns = try body.withUnsafeBytes { raw in
            try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
        }
        let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: 1)
        #expect(rows == [Row(ids: [Self.uuid(aBytes), Self.uuid(bBytes)])])
    }
}
