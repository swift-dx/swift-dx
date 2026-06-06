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

@Suite struct PostgresSubscriptionLimitTests {

    @Test func grantsUpToTheLimitThenFailsFast() throws {
        let pool = makePool(maxSubscriptions: 2)
        defer { pool.shutdown() }

        let first = try pool.acquireSubscriptionPermit()
        let second = try pool.acquireSubscriptionPermit()
        #expect(throws: PostgresError.subscriptionLimitReached(limit: 2)) {
            _ = try pool.acquireSubscriptionPermit()
        }

        _ = first
        _ = second
    }

    @Test func releasingAPermitFreesASlot() throws {
        let pool = makePool(maxSubscriptions: 1)
        defer { pool.shutdown() }

        let first = try pool.acquireSubscriptionPermit()
        #expect(throws: PostgresError.subscriptionLimitReached(limit: 1)) {
            _ = try pool.acquireSubscriptionPermit()
        }

        first.release()
        let reused = try pool.acquireSubscriptionPermit()
        reused.release()
    }

    @Test func releaseIsIdempotent() throws {
        let pool = makePool(maxSubscriptions: 1)
        defer { pool.shutdown() }

        let permit = try pool.acquireSubscriptionPermit()
        permit.release()
        permit.release()

        let reused = try pool.acquireSubscriptionPermit()
        reused.release()
    }

    private func makePool(maxSubscriptions: Int) -> PostgresLeasePool {
        var descriptors: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors)
        close(descriptors[1])
        return PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptors[0])], maxSubscriptions: maxSubscriptions)
    }
}
