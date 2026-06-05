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

@Suite struct PostgresOwnedResultTests {

    @Test func ownedExecutePreservesColumnsAndDistinguishesNull() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let response = rowDescription([("id", 23), ("note", 25)])
            + dataRow([.value(Array("ab".utf8)), .null])
            + commandComplete("SELECT 1")
            + readyForQuery
        response.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        defer { connection.close() }

        let result = try connection.execute("SELECT id, note FROM things")
        #expect(result.columns.map(\.name) == ["id", "note"])
        #expect(result.columns.map(\.dataTypeObjectID) == [23, 25])
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == [.bytes(Array("ab".utf8)), .sqlNull])
    }

    @Test func ownedExecuteCollectsEveryRowInOrderWithMixedNulls() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let response = rowDescription([("id", 23), ("note", 25)])
            + dataRow([.value(Array("1".utf8)), .value(Array("first".utf8))])
            + dataRow([.value(Array("2".utf8)), .null])
            + dataRow([.value(Array("3".utf8)), .value(Array("".utf8))])
            + commandComplete("SELECT 3")
            + readyForQuery
        response.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        defer { connection.close() }

        let result = try connection.execute("SELECT id, note FROM things")
        #expect(result.rows.count == 3)
        #expect(result.rows[0] == [.bytes(Array("1".utf8)), .bytes(Array("first".utf8))])
        #expect(result.rows[1] == [.bytes(Array("2".utf8)), .sqlNull])
        #expect(result.rows[2] == [.bytes(Array("3".utf8)), .bytes([])])
    }

    @Test func parameterizedQueryDecodesResultsOverTheExtendedProtocol() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let response = parseComplete + bindComplete
            + rowDescription([("id", 23), ("email", 25)])
            + dataRow([.value(Array("7".utf8)), .value(Array("a@b.com".utf8))])
            + commandComplete("SELECT 1")
            + readyForQuery
        response.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        defer { connection.close() }

        let injection = "x'); DROP TABLE users;--"
        let statement: PostgresStatement = "SELECT id, email FROM users WHERE email = \(injection)"
        let result = try connection.query(statement.sql, bindings: statement.bindings)

        #expect(statement.sql == "SELECT id, email FROM users WHERE email = $1")
        #expect(result.columns.map(\.name) == ["id", "email"])
        #expect(result.rows.count == 1)
        #expect(result.rows[0] == [.bytes(Array("7".utf8)), .bytes(Array("a@b.com".utf8))])
    }

    private var parseComplete: [UInt8] { [0x31, 0x00, 0x00, 0x00, 0x04] }

    private var bindComplete: [UInt8] { [0x32, 0x00, 0x00, 0x00, 0x04] }

    private enum Field {

        case value([UInt8])
        case null
    }

    private func rowDescription(_ columns: [(name: String, oid: Int32)]) -> [UInt8] {
        var body = bigEndianInt16(Int16(columns.count))
        for column in columns {
            body += cString(column.name)
            body += bigEndianInt32(0)
            body += bigEndianInt16(0)
            body += bigEndianInt32(column.oid)
            body += bigEndianInt16(4)
            body += bigEndianInt32(-1)
            body += bigEndianInt16(0)
        }
        return message(0x54, body)
    }

    private func dataRow(_ fields: [Field]) -> [UInt8] {
        var body = bigEndianInt16(Int16(fields.count))
        for field in fields {
            switch field {
            case .value(let bytes): body += bigEndianInt32(Int32(bytes.count)) + bytes
            case .null: body += bigEndianInt32(-1)
            }
        }
        return message(0x44, body)
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
