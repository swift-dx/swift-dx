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
import NIOPosix
import Testing
@testable import DXJetStream

@Suite
struct FetchStreamTests {

    @Test
    func fetchStream_anyAvailableWakesAfterFirstReply() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 1, inbox: "_INBOX.t.1", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 10, expires: .seconds(1), wait: .anyAvailable) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r1".utf8), headers: [])
        let result = try await task.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1"])
    }

    @Test
    func fetchStream_fillCollectsUntilBatch() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 2, inbox: "_INBOX.t.2", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 3, expires: .seconds(1), wait: .fill) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r1".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r2".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r3".utf8), headers: [])
        let result = try await task.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2", "r3"])
    }

    @Test
    func fetchStream_atLeastWakesAfterCount() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 3, inbox: "_INBOX.t.3", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 10, expires: .seconds(1), wait: .atLeast(2)) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r1".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r2".utf8), headers: [])
        let result = try await task.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2"])
    }

    @Test
    func fetchStream_capturesPayloadsWhenNeeded() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 4, inbox: "_INBOX.t.4", needsPayload: true, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 2, expires: .seconds(1), wait: .fill) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverReplyAndPayload(subject: Array("test.subject".utf8), reply: Array("r1".utf8), headers: [], payload: [0x01])
        fs.deliverReplyAndPayload(subject: Array("test.subject".utf8), reply: Array("r2".utf8), headers: [], payload: [0x02])
        let result = try await task.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2"])
        #expect(result.payloads == [[0x01], [0x02]])
    }

    @Test
    func fetchStream_status404WakesWithAccumulated() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 5, inbox: "_INBOX.t.5", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 10, expires: .seconds(1), wait: .fill) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("partial".utf8), headers: [])
        fs.deliverStatus(404)
        let result = try await task.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["partial"])
    }

    @Test
    func fetchStream_status408WakesWithAccumulated() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 6, inbox: "_INBOX.t.6", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 10, expires: .seconds(1), wait: .fill) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverStatus(408)
        let result = try await task.value
        #expect(result.replies.isEmpty)
    }

    @Test
    func fetchStream_status100KeepsWaiting() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 7, inbox: "_INBOX.t.7", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 2, expires: .seconds(1), wait: .fill) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverStatus(100)
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r1".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r2".utf8), headers: [])
        let result = try await task.value
        #expect(result.replies.map { String(decoding: $0, as: UTF8.self) } == ["r1", "r2"])
    }

    @Test
    func fetchStream_closeWakesParkedWaiter() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 8, inbox: "_INBOX.t.8", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 10, expires: .seconds(1), wait: .fill) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.close()
        let result = try await task.value
        #expect(result.replies.isEmpty)
    }

    @Test
    func fetchStream_extraRepliesBeyondBatchAreLeftForNextCall() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 9, inbox: "_INBOX.t.9", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r1".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r2".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r3".utf8), headers: [])
        let result1 = try await fs.requestAndAwait(batch: 2, expires: .seconds(1), wait: .anyAvailable)
        #expect(result1.repliesAsStrings == ["r1", "r2"])
        let result2 = try await fs.requestAndAwait(batch: 5, expires: .seconds(1), wait: .anyAvailable)
        #expect(result2.repliesAsStrings == ["r3"])
    }

    @Test
    func fetchStream_resolveMinimumClampsAtLeast() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let fs = FetchStream(sid: 10, inbox: "_INBOX.t.10", needsPayload: false, pubSubject: "$JS.X", connection: conn)
        let task = Task { try await fs.requestAndAwait(batch: 3, expires: .seconds(1), wait: .atLeast(100)) }
        try await Task.sleep(nanoseconds: 5_000_000)
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r1".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r2".utf8), headers: [])
        fs.deliverReply(subject: Array("test.subject".utf8), reply: Array("r3".utf8), headers: [])
        let result = try await task.value
        #expect(result.replies.count == 3)
    }
}
