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
struct PendingFetchRaceTests {

    @Test
    func parkedThenDeliveryReachesBatch_finalizesContinuationViaParkedPath() async throws {
        let pending = PendingFetch(batch: 1, needsPayload: false)
        let waitTask = Task { try await pending.wait() }
        for _ in 0..<50 { await Task.yield() }
        let done = pending.deliverReply(Array("r1".utf8))
        #expect(done)
        let result = try await waitTask.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1"])
    }

    @Test
    func parkedThenStatus404_finalizesContinuationWithAccumulated() async throws {
        let pending = PendingFetch(batch: 10, needsPayload: false)
        _ = pending.deliverReply(Array("partial".utf8))
        let waitTask = Task { try await pending.wait() }
        for _ in 0..<50 { await Task.yield() }
        let done = pending.deliverStatus(404)
        #expect(done)
        let result = try await waitTask.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["partial"])
    }

    @Test
    func waitCalledTwice_secondWaitFailsWithProtocolError() async throws {
        let pending = PendingFetch(batch: 5, needsPayload: false)
        let firstWait = Task { try await pending.wait() }
        for _ in 0..<50 { await Task.yield() }
        let secondWait = Task { try await pending.wait() }
        let secondOutcome: Result<PendingFetch.FetchResult, any Error> = await secondWait.result
        switch secondOutcome {
        case .failure(let error):
            switch error as? JetStreamError {
            case .protocolError(let reason): #expect(reason.contains("twice"))
            default: Issue.record("expected protocolError; got \(error)")
            }
        case .success: Issue.record("expected the second wait to fail")
        }
        pending.completeOnDeadline()
        _ = try? await firstWait.value
    }
}
