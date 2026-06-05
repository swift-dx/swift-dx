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
import Synchronization
@testable import DXPostgres

@Suite struct PostgresLeasePoolShutdownTests {

    @Test(.timeLimit(.minutes(1)))
    func shutdownFailsParkedWaiterInsteadOfHanging() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        defer { close(descriptors[1]) }
        let pool = PostgresLeasePool(connections: [connection])

        let occupied = Mutex(false)
        let release = DispatchSemaphore(value: 0)

        let holder = Task {
            try await pool.withConnection { _ in
                occupied.withLock { $0 = true }
                release.wait()
            }
        }
        while !(occupied.withLock { $0 }) { await Task.yield() }

        let waiter = Task { () -> Bool in
            do {
                try await pool.withConnection { _ in }
                return false
            } catch {
                guard let postgres = error as? PostgresError, case .poolShutdown = postgres else { return false }
                return true
            }
        }
        while pool.waiterCount == 0 { await Task.yield() }

        pool.shutdown()
        #expect(await waiter.value)

        release.signal()
        _ = try? await holder.value
    }

    @Test(.timeLimit(.minutes(1)))
    func droppingThePoolWithoutShutdownReleasesItsConnection() {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        openPoolAndDrop(descriptors[0])

        var released = false
        for _ in 0..<2000 {
            if fcntl(descriptors[0], F_GETFD) == -1 { released = true; break }
            usleep(1000)
        }
        #expect(released)
    }

    private func openPoolAndDrop(_ descriptor: Int32) {
        let pool = PostgresLeasePool(connections: [BlockingPostgresConnection(descriptor: descriptor)])
        _ = pool.waiterCount
    }
}
