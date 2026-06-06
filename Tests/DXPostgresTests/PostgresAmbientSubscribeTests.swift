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

@Suite struct PostgresAmbientSubscribeTests {

    @Test func ambientSubscribeWithoutABoundClientThrowsNoCurrentClient() throws {
        #expect(throws: PostgresError.noCurrentClient) {
            _ = try Postgres.subscribe(channels: ["cache_invalidation"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func ambientSubscribeWithAFixedClientThrowsNoCurrentClient() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])])
        defer { pool.shutdown() }

        try await Postgres.withCurrent(pool) {
            #expect(throws: PostgresError.noCurrentClient) {
                _ = try Postgres.subscribe(channels: ["cache_invalidation"])
            }
        }
    }
}
