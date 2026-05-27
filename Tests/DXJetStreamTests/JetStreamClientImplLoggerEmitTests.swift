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
import Logging
import NIOPosix
@testable import DXJetStream

@Suite
struct JetStreamClientImplLoggerEmitTests {

    private func makeClientWithCapturingLogger() -> (JetStreamClientImpl, CapturingLogHandler) {
        let handler = CapturingLogHandler()
        let logger = Logger(label: "test", factory: { _ in handler })
        let natsLogger = NatsLogger(logger)
        let client = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton, logger: natsLogger)
        return (client, handler)
    }

    @Test
    func enqueuePayloads_emitsPublishStartedWhenLoggerNotSilent() async throws {
        let (client, handler) = makeClientWithCapturingLogger()
        let subject = try Subject("test.subject")
        _ = client.enqueue(to: subject, payloads: [Array("hello".utf8)])
        let publishStartedEntries = handler.entries.filter { $0.message == "publish.batch_started" }
        #expect(publishStartedEntries.count == 1)
        await client.close()
    }

    @Test
    func enqueueMessages_emitsPublishStartedWhenLoggerNotSilent() async throws {
        let (client, handler) = makeClientWithCapturingLogger()
        let subject = try Subject("test.subject")
        let message = NatsOutgoingMessage(dedup: .dedupId("test-1"), payload: Array("body".utf8))
        _ = client.enqueue(to: subject, messages: [message])
        let publishStartedEntries = handler.entries.filter { $0.message == "publish.batch_started" }
        #expect(publishStartedEntries.count == 1)
        await client.close()
    }

    @Test
    func ackWithNoReply_doesNothing() async {
        let (client, _) = makeClientWithCapturingLogger()
        let message = NatsMessage(subject: "no.reply", sid: 1, reply: .none, headers: [], payload: [], status: .ok)
        client.ack(message)
        await client.close()
    }

    @Test
    func ackWithReply_acknowledgesThroughChannel() async {
        let (client, _) = makeClientWithCapturingLogger()
        let message = NatsMessage(subject: "has.reply", sid: 1, reply: .subject("$JS.ACK.123"), headers: [], payload: [], status: .ok)
        client.ack(message)
        await client.close()
    }

    @Test
    func run_returnsAfterTaskCancellation() async {
        let (client, _) = makeClientWithCapturingLogger()
        let task = Task<Void, any Error> {
            try await client.run()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = try? await task.value
        await client.close()
    }
}
