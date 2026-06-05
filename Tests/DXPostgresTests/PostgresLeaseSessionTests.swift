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

@Suite struct PostgresLeaseSessionTests {

    @Test(.timeLimit(.minutes(1)))
    func multipleStatementsInOneLeaseRunOnTheSameConnection() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let oneStatement = commandComplete + readyForQuery
        let canned = oneStatement + oneStatement
        canned.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])])
        defer { pool.shutdown() }

        let rowCounts = try await pool.withConnection { connection -> [Int] in
            let first = try connection.execute("SELECT 1")
            let second = try connection.execute("SELECT 2")
            return [first.rows.count, second.rows.count]
        }
        #expect(rowCounts == [0, 0])
    }

    private var commandComplete: [UInt8] { [0x43, 0x00, 0x00, 0x00, 0x07, 0x4F, 0x4B, 0x00] }

    private var readyForQuery: [UInt8] { [0x5A, 0x00, 0x00, 0x00, 0x05, 0x49] }
}
