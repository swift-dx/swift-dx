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

import NIOCore
import Testing
@testable import DXJetStream

@Suite
struct PendingFetchTests {

    @Test
    func pendingFetch_completesWhenBatchReached() async throws {
        let pending = PendingFetch(batch: 3, needsPayload: false)
        _ = pending.deliverReply(Array("r1".utf8))
        _ = pending.deliverReply(Array("r2".utf8))
        let done = pending.deliverReply(Array("r3".utf8))
        #expect(done)
        let result = try await pending.wait()
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2", "r3"])
        #expect(result.payloads.isEmpty)
    }

    @Test
    func pendingFetch_capturesPayloadsWhenRequested() async throws {
        let pending = PendingFetch(batch: 2, needsPayload: true)
        _ = pending.deliverReplyAndPayload(Array("r1".utf8), payload: [0x01])
        _ = pending.deliverReplyAndPayload(Array("r2".utf8), payload: [0x02, 0x03])
        let result = try await pending.wait()
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2"])
        #expect(result.payloads == [[0x01], [0x02, 0x03]])
    }

    @Test
    func pendingFetch_status404TerminatesWithAccumulated() async throws {
        let pending = PendingFetch(batch: 10, needsPayload: false)
        _ = pending.deliverReply(Array("partial1".utf8))
        _ = pending.deliverReply(Array("partial2".utf8))
        let done = pending.deliverStatus(404)
        #expect(done)
        let result = try await pending.wait()
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["partial1", "partial2"])
    }

    @Test
    func pendingFetch_status408TerminatesWithAccumulated() async throws {
        let pending = PendingFetch(batch: 10, needsPayload: false)
        _ = pending.deliverReply(Array("r".utf8))
        _ = pending.deliverStatus(408)
        let result = try await pending.wait()
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r"])
    }

    @Test
    func pendingFetch_status100KeepsAccumulating() async throws {
        let pending = PendingFetch(batch: 2, needsPayload: false)
        let done = pending.deliverStatus(100)
        #expect(!done)
        _ = pending.deliverReply(Array("r1".utf8))
        _ = pending.deliverReply(Array("r2".utf8))
        let result = try await pending.wait()
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2"])
    }

    @Test
    func pendingFetch_unexpectedStatusFailsWait() async {
        let pending = PendingFetch(batch: 2, needsPayload: false)
        _ = pending.deliverStatus(500)
        await #expect(throws: JetStreamError.self) {
            _ = try await pending.wait()
        }
    }

    @Test
    func pendingFetch_deadlineCompletesEmpty() async throws {
        let pending = PendingFetch(batch: 5, needsPayload: false)
        pending.completeOnDeadline()
        let result = try await pending.wait()
        #expect(result.replies.isEmpty)
    }

    @Test
    func pendingFetch_failWithPropagatesError() async {
        let pending = PendingFetch(batch: 5, needsPayload: false)
        pending.failWith(JetStreamError.protocolError(reason: "test"))
        await #expect(throws: JetStreamError.self) {
            _ = try await pending.wait()
        }
    }

    @Test
    func pendingFetch_waitBeforeBatchParksThenCompletes() async throws {
        let pending = PendingFetch(batch: 2, needsPayload: false)
        let task = Task { try await pending.wait() }
        _ = pending.deliverReply(Array("r1".utf8))
        _ = pending.deliverReply(Array("r2".utf8))
        let result = try await task.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2"])
    }
}
