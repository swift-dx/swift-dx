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
@testable import DXJetStream

@Suite
struct PendingBarrierTests {

    @Test
    func barrier_waitReturnsImmediatelyWhenAlreadyDone() async throws {
        let barrier = PendingBarrier(count: 1)
        barrier.arrive()
        try await barrier.wait()
    }

    @Test
    func barrier_arrivesAfterWaitRegisters() async throws {
        let barrier = PendingBarrier(count: 3)
        let task = Task {
            try await barrier.wait()
        }
        barrier.arrive()
        barrier.arrive()
        barrier.arrive()
        try await task.value
    }

    @Test
    func barrier_handlesAllArrivalsBeforeWait() async throws {
        let barrier = PendingBarrier(count: 5)
        for _ in 0..<5 {
            barrier.arrive()
        }
        try await barrier.wait()
    }

    @Test
    func barrier_pipelinedRaceBetweenLastArriveAndWaitRegistration() async throws {
        for _ in 0..<256 {
            let barrier = PendingBarrier(count: 2)
            let waitTask = Task {
                try await barrier.wait()
            }
            let arriveTask = Task {
                barrier.arrive()
                barrier.arrive()
            }
            try await waitTask.value
            await arriveTask.value
        }
    }

    @Test
    func barrier_concurrentArrivalsFromManyTasks() async throws {
        let count = 1000
        let barrier = PendingBarrier(count: count)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    barrier.arrive()
                }
            }
        }
        try await barrier.wait()
    }
}
