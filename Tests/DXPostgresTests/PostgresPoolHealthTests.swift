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

@Suite struct PostgresPoolHealthTests {

    @Test(.timeLimit(.minutes(1)))
    func aDeadConnectionIsMarkedDownAndStopsCountingAsHealthy() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)

        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])])
        defer { pool.shutdown() }
        #expect(pool.healthyConnectionCount == 1)

        close(descriptors[1])

        await #expect(throws: PostgresError.self) {
            _ = try await pool.execute("SELECT 1")
        }
        #expect(pool.healthyConnectionCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func leasingWhenEveryConnectionIsDownFailsFastInsteadOfBlocking() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)

        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])])
        defer { pool.shutdown() }

        close(descriptors[1])

        await #expect(throws: PostgresError.self) {
            _ = try await pool.execute("SELECT 1")
        }

        await #expect(throws: PostgresError.allConnectionsDown) {
            _ = try await pool.execute("SELECT 1")
        }
    }
}
