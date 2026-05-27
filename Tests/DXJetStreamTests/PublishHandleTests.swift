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

import NIOPosix
import Testing
@testable import DXJetStream

@Suite
struct PublishHandleTests {

    @Test
    func publishHandle_unregistersBarrierAfterWait() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let subject = try Subject("publish.test")
        let handle = conn.enqueue(to: subject, payloads: [[0x01]])
        _ = conn.dispatchBarrierByRange(suffix: 1)
        try await handle.wait()
        #expect(!conn.dispatchBarrierByRange(suffix: 1))
    }

    @Test
    func publishHandle_completesAfterAllArrive() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let subject = try Subject("publish.test")
        let payloads: [[UInt8]] = [[0x01], [0x02], [0x03]]
        let handle = conn.enqueue(to: subject, payloads: payloads)
        let waiter = Task { try await handle.wait() }
        _ = conn.dispatchBarrierByRange(suffix: 1)
        _ = conn.dispatchBarrierByRange(suffix: 2)
        _ = conn.dispatchBarrierByRange(suffix: 3)
        try await waiter.value
    }
}
