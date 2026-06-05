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
import Foundation
import Glibc
@testable import DXPostgres

@Suite struct PostgresStatementCacheTests {

    @Test(.timeLimit(.minutes(1)))
    func preparedStatementCacheStaysBoundedAcrossManyDistinctQueries() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        let peer = descriptors[1]
        defer { close(peer) }

        let distinct = 520
        var canned: [UInt8] = []
        for _ in 0..<distinct {
            canned += scalarRow(1)
            canned += readyForQuery
        }
        canned.withUnsafeBytes { _ = write(peer, $0.baseAddress, $0.count) }

        let drain = Thread {
            var scratch = [UInt8](repeating: 0, count: 4096)
            while scratch.withUnsafeMutableBytes({ read(peer, $0.baseAddress, $0.count) }) > 0 {}
        }
        drain.stackSize = 1 << 20
        drain.start()

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        defer { connection.close() }

        var index = 0
        while index < distinct {
            _ = try connection.queryScalarInt64Inline("SELECT $1::int8 -- variant \(index)", value: 1)
            index += 1
        }
        #expect(connection.cachedStatementCount <= 512)
    }

    private func scalarRow(_ value: Int64) -> [UInt8] {
        let body = bigEndianInt16(1) + bigEndianInt32(8) + bigEndianInt64(value)
        return [0x44] + bigEndianInt32(Int32(body.count + 4)) + body
    }

    private var readyForQuery: [UInt8] {
        [0x5A] + bigEndianInt32(5) + [0x49]
    }

    private func bigEndianInt16(_ value: Int16) -> [UInt8] {
        let bits = UInt16(bitPattern: value)
        return [UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }

    private func bigEndianInt32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }

    private func bigEndianInt64(_ value: Int64) -> [UInt8] {
        let bits = UInt64(bitPattern: value)
        var bytes: [UInt8] = []
        var shift = 56
        while shift >= 0 {
            bytes.append(UInt8(bits >> UInt64(shift) & 0xFF))
            shift -= 8
        }
        return bytes
    }
}
