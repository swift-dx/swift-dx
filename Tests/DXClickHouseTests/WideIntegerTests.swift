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

@Suite("DXClickHouse wide integer columns")
struct ClickHouseWideIntegerTests {

    struct I128: Codable, Sendable, Equatable { let v: ClickHouseInt128 }
    struct I256: Codable, Sendable, Equatable { let v: ClickHouseInt256 }

    @Test("Int128 writes 16 little-endian bytes and decodes back")
    func int128() throws {
        let columns = try ClickHouseRowEncoder().encode([I128(v: ClickHouseInt128(Int128(0x0102_0304_0506_0708)))])
        #expect(columns[0].column.typeName == "Int128")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        #expect(Array(packet.suffix(16)) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0, 0, 0, 0, 0, 0, 0, 0])

        let decoded: [ClickHouseNamedColumn] = [ClickHouseNamedColumn(name: "v", column: .int128([Int128(0x0102_0304_0506_0708), -5]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: I128.self, columns: decoded, rowCount: 2)
        #expect(rows == [I128(v: ClickHouseInt128(Int128(0x0102_0304_0506_0708))), I128(v: ClickHouseInt128(-5))])
    }

    @Test("Int256 writes four little-endian UInt64 limbs and decodes back")
    func int256() throws {
        let columns = try ClickHouseRowEncoder().encode([I256(v: ClickHouseInt256(limb0: 0x1122_3344_5566_7788, limb1: 0, limb2: 0, limb3: 0))])
        #expect(columns[0].column.typeName == "Int256")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        var expected: [UInt8] = []
        withUnsafeBytes(of: UInt64(0x1122_3344_5566_7788).littleEndian) { expected.append(contentsOf: $0) }
        expected.append(contentsOf: [UInt8](repeating: 0, count: 24))
        #expect(Array(packet.suffix(32)) == expected)

        let value = ClickHouseInt256(limb0: 1, limb1: 2, limb2: 3, limb3: 4)
        let decoded: [ClickHouseNamedColumn] = [ClickHouseNamedColumn(name: "v", column: .int256([value]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: I256.self, columns: decoded, rowCount: 1)
        #expect(rows == [I256(v: value)])
    }
}
