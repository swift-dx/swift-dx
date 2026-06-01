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

@Suite("DXClickHouse Date32 / IPv4 / IPv6 columns")
struct ClickHouseDate32IPTests {

    struct D32: Codable, Sendable, Equatable { let d: ClickHouseDate32 }
    struct IP4: Codable, Sendable, Equatable { let ip: ClickHouseIPv4 }
    struct IP6: Codable, Sendable, Equatable { let ip: ClickHouseIPv6 }

    @Test("Date32 writes a little-endian Int32 and decodes back")
    func date32() throws {
        let columns = try ClickHouseRowEncoder().encode([D32(d: ClickHouseDate32(days: 20000))])
        #expect(columns[0].column.typeName == "Date32")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        var expected: [UInt8] = []
        withUnsafeBytes(of: Int32(20000).littleEndian) { expected.append(contentsOf: $0) }
        #expect(Array(packet.suffix(4)) == expected)

        let decoded: [ClickHouseNamedColumn] = [ClickHouseNamedColumn(name: "d", column: .date32([20000, -1000]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: D32.self, columns: decoded, rowCount: 2)
        #expect(rows == [D32(d: ClickHouseDate32(days: 20000)), D32(d: ClickHouseDate32(days: -1000))])
    }

    @Test("IPv4 writes a little-endian UInt32 with the first octet most significant")
    func ipv4() throws {
        let columns = try ClickHouseRowEncoder().encode([IP4(ip: ClickHouseIPv4(raw: 0x7F00_0001))])
        #expect(columns[0].column.typeName == "IPv4")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        #expect(Array(packet.suffix(4)) == [0x01, 0x00, 0x00, 0x7F])

        let decoded: [ClickHouseNamedColumn] = [ClickHouseNamedColumn(name: "ip", column: .ipv4([0x7F00_0001]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: IP4.self, columns: decoded, rowCount: 1)
        #expect(rows == [IP4(ip: ClickHouseIPv4(raw: 0x7F00_0001))])
    }

    @Test("IPv6 pads to 16 raw bytes and decodes back")
    func ipv6() throws {
        var loopback = [UInt8](repeating: 0, count: 16)
        loopback[15] = 1
        let columns = try ClickHouseRowEncoder().encode([IP6(ip: ClickHouseIPv6(bytes: loopback))])
        #expect(columns[0].column.typeName == "IPv6")
        let packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseBlockWriter.revisionWithCustomSerialization)
        #expect(Array(packet.suffix(16)) == loopback)

        let decoded: [ClickHouseNamedColumn] = [ClickHouseNamedColumn(name: "ip", column: .ipv6([loopback]))]
        let rows = try ClickHouseCodableDecoder.decodeRows(type: IP6.self, columns: decoded, rowCount: 1)
        #expect(rows == [IP6(ip: ClickHouseIPv6(bytes: loopback))])
    }
}
