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

@Suite struct PostgresNotifyTests {

    @Test(.timeLimit(.minutes(1)))
    func notifyBindsChannelAndPayloadAsParametersOverThePool() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let response = parseComplete + bindComplete
            + rowDescription([("pg_notify", 2278)])
            + dataRow([.value([])])
            + commandComplete("SELECT 1")
            + readyForQuery
        response.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])])
        defer { pool.shutdown() }

        try await pool.notify(channel: "cache_invalidation", payload: "user:42")

        let frontend = readAvailable(from: descriptors[1])
        #expect(contains(frontend, Array("SELECT pg_notify($1, $2)".utf8)))
        #expect(contains(frontend, Array("cache_invalidation".utf8)))
        #expect(contains(frontend, Array("user:42".utf8)))
        #expect(!contains(frontend, Array("'cache_invalidation'".utf8)))
    }

    private func readAvailable(from descriptor: Int32) -> [UInt8] {
        var flags = fcntl(descriptor, F_GETFL)
        flags |= Int32(O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFL, flags)
        var collected: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = scratch.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            collected += scratch[0..<count]
        }
        return collected
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count, !needle.isEmpty else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
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
