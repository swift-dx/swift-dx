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

@Suite struct LeaseWorkerTests {

    private func makeWorker() -> (worker: LeaseWorker, peer: Int32) {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        return (LeaseWorker(connection: connection), descriptors[1])
    }

    @Test func runningWorkerAcceptsAndRunsJobs() {
        let (worker, peer) = makeWorker()
        defer { close(peer) }
        worker.start()
        let ran = DispatchSemaphore(value: 0)
        let accepted = worker.submitJob { ran.signal() }
        #expect(accepted)
        #expect(ran.wait(timeout: .now() + 5) == .success)
        worker.stop()
    }

    @Test func stoppedWorkerRejectsJobsInsteadOfDroppingThem() {
        let (worker, peer) = makeWorker()
        defer { close(peer) }
        worker.start()
        worker.stop()
        #expect(worker.submitJob { } == false)
    }
}
