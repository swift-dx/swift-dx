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

import Testing
import Glibc
@testable import DXPostgres

@Suite struct PostgresStreamResyncTests {

    @Test func throwingRowClosureLeavesConnectionUsableForTheNextQuery() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        let clientDescriptor = descriptors[0]
        let serverDescriptor = descriptors[1]
        defer { close(serverDescriptor) }

        let firstResult = rowDescription(name: "n") + dataRow("1") + dataRow("2") + dataRow("3") + commandComplete("SELECT 3") + readyForQuery
        let secondResult = rowDescription(name: "answer") + dataRow("42") + commandComplete("SELECT 1") + readyForQuery
        let canned = firstResult + secondResult
        canned.withUnsafeBytes { raw in
            _ = write(serverDescriptor, raw.baseAddress, raw.count)
        }

        let connection = BlockingPostgresConnection(descriptor: clientDescriptor)
        defer { connection.close() }

        #expect(throws: PostgresError.self) {
            try connection.execute("SELECT generate_series(1, 3) AS n") { (_: PostgresRowView) throws(PostgresError) in
                throw PostgresError.protocolError(reason: "caller rejected the row")
            }
        }

        let recovered = try connection.execute("SELECT 42 AS answer")
        #expect(try recovered.rows[0][0].text() == "42")
    }

    private func rowDescription(name: String) -> [UInt8] {
        var body = bigEndianInt16(1)
        body += cString(name)
        body += bigEndianInt32(0)
        body += bigEndianInt16(0)
        body += bigEndianInt32(23)
        body += bigEndianInt16(4)
        body += bigEndianInt32(-1)
        body += bigEndianInt16(0)
        return message(0x54, body)
    }

    private func dataRow(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return message(0x44, bigEndianInt16(1) + bigEndianInt32(Int32(bytes.count)) + bytes)
    }

    private func commandComplete(_ tag: String) -> [UInt8] {
        message(0x43, cString(tag))
    }

    private var readyForQuery: [UInt8] {
        message(0x5A, [0x49])
    }

    private func message(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + bigEndianInt32(Int32(body.count + 4)) + body
    }

    private func cString(_ value: String) -> [UInt8] {
        Array(value.utf8) + [0]
    }

    private func bigEndianInt16(_ value: Int16) -> [UInt8] {
        let bits = UInt16(bitPattern: value)
        return [UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }

    private func bigEndianInt32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }
}
