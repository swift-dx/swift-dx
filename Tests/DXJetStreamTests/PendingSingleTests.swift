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
struct PendingSingleTests {

    @Test
    func pendingSingle_completesBeforeWait() async throws {
        let pending = PendingSingle()
        let message = NatsMessage(subject: "x", sid: 1, reply: .none, payload: [1, 2, 3], status: .ok)
        pending.complete(.success(message))
        let received = try await pending.wait()
        #expect(received.subject == "x")
        #expect(received.payload == [1, 2, 3])
    }

    @Test
    func pendingSingle_waitThenComplete() async throws {
        let pending = PendingSingle()
        let task = Task { try await pending.wait() }
        let message = NatsMessage(subject: "y", sid: 2, reply: .subject("reply.1"), payload: [], status: .ok)
        pending.complete(.success(message))
        let received = try await task.value
        #expect(received.sid == 2)
        if case .subject(let value) = received.reply {
            #expect(value == "reply.1")
        } else {
            Issue.record("Expected reply.subject case")
        }
    }

    @Test
    func pendingSingle_propagatesError() async {
        let pending = PendingSingle()
        pending.complete(.failure(JetStreamError.protocolError(reason: "boom")))
        await #expect(throws: JetStreamError.self) {
            _ = try await pending.wait()
        }
    }

    @Test
    func pendingSingle_secondCompleteIsIgnored() async throws {
        let pending = PendingSingle()
        let first = NatsMessage(subject: "first", sid: 1, reply: .none, payload: [], status: .ok)
        let second = NatsMessage(subject: "second", sid: 2, reply: .none, payload: [], status: .ok)
        pending.complete(.success(first))
        pending.complete(.success(second))
        let received = try await pending.wait()
        #expect(received.subject == "first")
    }

    @Test
    func pendingSingle_secondWaitFailsWithProtocolError() async throws {
        let pending = PendingSingle()
        let firstWaiter = Task { try await pending.wait() }
        try await Task.sleep(nanoseconds: 5_000_000)
        let secondWaiter = Task { try await pending.wait() }
        await #expect(throws: JetStreamError.self) {
            _ = try await secondWaiter.value
        }
        pending.complete(.success(NatsMessage(subject: "x", sid: 1, reply: .none, payload: [], status: .ok)))
        _ = try await firstWaiter.value
    }
}
