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

@Suite struct PostgresTransactionTests {

    private struct BusinessRuleViolation: Error {}

    @Test(.timeLimit(.minutes(1)))
    func transactionCommitsAndReturnsTheBodyResult() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let canned = completed("BEGIN") + completed("INSERT 0 1") + completed("COMMIT")
        canned.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])])
        defer { pool.shutdown() }

        let rowCount = try await pool.transaction { tx -> Int in
            let result = try tx.execute("INSERT INTO t VALUES (1)")
            return result.rows.count
        }
        #expect(rowCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func transactionRollsBackAndRethrowsTheBodyError() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let canned = completed("BEGIN") + completed("INSERT 0 1") + completed("ROLLBACK")
        canned.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])])
        defer { pool.shutdown() }

        await #expect(throws: BusinessRuleViolation.self) {
            _ = try await pool.transaction { (tx: PostgresTransaction) -> Int in
                _ = try tx.execute("INSERT INTO t VALUES (1)")
                throw BusinessRuleViolation()
            }
        }
    }

    private func completed(_ tag: String) -> [UInt8] {
        let body = Array(tag.utf8) + [0]
        let commandComplete = [0x43] + bigEndianInt32(Int32(body.count + 4)) + body
        let readyForQuery: [UInt8] = [0x5A, 0x00, 0x00, 0x00, 0x05, 0x49]
        return commandComplete + readyForQuery
    }

    private func bigEndianInt32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }
}
