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

@Suite("DXClickHouse BFloat16 column")
struct ClickHouseBFloat16Tests {

    struct BF: Codable, Sendable, Equatable { let value: ClickHouseBFloat16 }

    @Test("1.5 has no low-half bits and writes the upper 16 bits unchanged")
    func exactValueWritesUpperHalf() throws {
        let columns = try ClickHouseRowEncoder().encode([BF(value: ClickHouseBFloat16(float: 1.5))])
        #expect(columns[0].column.typeName == "BFloat16")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        #expect(Array(packet.suffix(2)) == [0xC0, 0x3F])
    }

    @Test("3.14 rounds the discarded low half to nearest, ties to even")
    func lossyValueRoundsToNearest() throws {
        let columns = try ClickHouseRowEncoder().encode([BF(value: ClickHouseBFloat16(float: 3.14))])
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        #expect(Array(packet.suffix(2)) == [0x49, 0x40])
        #expect(ClickHouseBFloat16(float: 3.14).rawBits == 0x4049)
    }

    @Test("decode expands the 16-bit pattern back into a Float32")
    func decodeExpandsToFloat() throws {
        let decoded: [ClickHouseNamedColumn] = [
            ClickHouseNamedColumn(name: "value", column: .bfloat16([0x3FC0, 0x4049]))
        ]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: BF.self, columns: decoded, rowCount: 2)
        #expect(rows[0].value.float == 1.5)
        #expect(rows[1].value.float == 3.140625)
    }

    @Test("encode then decode reproduces the BFloat16-quantized value")
    func roundTripQuantized() throws {
        let inputs: [Float] = [1.5, 3.14, 0.5, -2.5, 1.0]
        let columns = try ClickHouseRowEncoder().encode(inputs.map { BF(value: ClickHouseBFloat16(float: $0)) })
        let typed = columns[0].column
        guard case .bfloat16(let bits) = typed else {
            Issue.record("expected bfloat16 column")
            return
        }
        let decoded: [ClickHouseNamedColumn] = [ClickHouseNamedColumn(name: "value", column: .bfloat16(bits))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: BF.self, columns: decoded, rowCount: inputs.count)
        for (index, input) in inputs.enumerated() {
            let expected = Float(bitPattern: UInt32(ClickHouseBFloat16(float: input).rawBits) << 16)
            #expect(rows[index].value.float == expected)
        }
    }
}
