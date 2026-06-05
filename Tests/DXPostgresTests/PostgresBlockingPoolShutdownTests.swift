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

@Suite struct PostgresBlockingPoolShutdownTests {

    @Test(.timeLimit(.minutes(1)))
    func queryAfterShutdownThrowsPoolShutdownInsteadOfHanging() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        defer { close(descriptors[1]) }
        let pool = PostgresBlockingPool(connections: [connection])
        pool.shutdown()

        do {
            _ = try await pool.queryScalarInt64("SELECT $1::int8", value: 1)
            Issue.record("expected a pool-shutdown error after shutdown")
        } catch let error as PostgresError {
            guard case .poolShutdown = error else {
                Issue.record("expected poolShutdown, got \(error)")
                return
            }
        }
    }
}
