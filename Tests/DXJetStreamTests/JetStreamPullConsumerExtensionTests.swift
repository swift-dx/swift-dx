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
import DXCore
@testable import DXJetStream

@Suite
struct JetStreamPullConsumerExtensionTests {

    @Test
    func handlerWrap_dispatchesEachMessageThroughHandler() async throws {
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        let messages: [NatsMessage] = [
            NatsMessage(subject: "orders.created.1", sid: 1, reply: .none, headers: [], payload: Array("first".utf8), status: .ok),
            NatsMessage(subject: "orders.created.2", sid: 1, reply: .none, headers: [], payload: Array("second".utf8), status: .ok),
        ]
        let mock = MockPullConsumer(messages: messages, error: .none)
        let handler = RecordingMessageHandler()

        let subscription = mock.messages(from: stream, for: consumer, handler: handler)
        await waitForMessages(handler: handler, atLeast: 2)
        subscription.cancel()

        #expect(handler.received.count == 2)
        #expect(handler.received[0].subject == "orders.created.1")
        #expect(handler.received[1].subject == "orders.created.2")
        #expect(handler.errors.isEmpty)
    }

    @Test
    func handlerWrap_dispatchesJetStreamErrorThroughHandler() async throws {
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        let mock = MockPullConsumer(messages: [], error: .typed(.notConnected))
        let handler = RecordingMessageHandler()

        let subscription = mock.messages(from: stream, for: consumer, handler: handler)
        await waitForError(handler: handler)
        subscription.cancel()

        #expect(handler.received.isEmpty)
        #expect(handler.errors.count == 1)
        #expect(handler.errors[0] == .notConnected)
    }

    @Test
    func handlerWrap_wrapsForeignErrorAsTransportError() async throws {
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        let mock = MockPullConsumer(messages: [], error: .foreign(FakeError.boom))
        let handler = RecordingMessageHandler()

        let subscription = mock.messages(from: stream, for: consumer, handler: handler)
        await waitForError(handler: handler)
        subscription.cancel()

        #expect(handler.errors.count == 1)
        switch handler.errors[0] {
        case .transportError(let reason):
            #expect(reason.contains("boom"))
        default:
            Issue.record("expected transportError, got \(handler.errors[0])")
        }
    }

    @Test
    func handlerWrap_withOptions_dispatchesMessages() async throws {
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        let messages: [NatsMessage] = [
            NatsMessage(subject: "orders.created.x", sid: 1, reply: .none, headers: [], payload: Array("payload".utf8), status: .ok),
        ]
        let mock = MockPullConsumer(messages: messages, error: .none)
        let handler = RecordingMessageHandler()

        let subscription = mock.messages(from: stream, for: consumer, options: PullOptions(), handler: handler)
        await waitForMessages(handler: handler, atLeast: 1)
        subscription.cancel()

        #expect(handler.received.count == 1)
        #expect(handler.received[0].subject == "orders.created.x")
    }

    @Test
    func asyncStreamConvenience_withDefaultOptions_yieldsMessages() async throws {
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        let messages: [NatsMessage] = [
            NatsMessage(subject: "orders.created.q", sid: 1, reply: .none, headers: [], payload: Array("p".utf8), status: .ok),
        ]
        let mock = MockPullConsumer(messages: messages, error: .none)

        let asyncStream = mock.messages(from: stream, for: consumer)
        var received: [NatsMessage] = []
        for try await message in asyncStream {
            received.append(message)
            if received.count >= 1 { break }
        }
        #expect(received.count == 1)
        #expect(received[0].subject == "orders.created.q")
    }
}

private enum FakeError: Error {

    case boom
}

private enum MockOutcome: Sendable {

    case none
    case typed(JetStreamError)
    case foreign(any Error)
}

private final class MockPullConsumer: JetStreamPullConsumer, @unchecked Sendable {

    let preparedMessages: [NatsMessage]
    let outcome: MockOutcome

    init(messages: [NatsMessage], error: MockOutcome) {
        self.preparedMessages = messages
        self.outcome = error
    }

    func fetch(from stream: StreamName, for consumer: ConsumerName, needsPayload: Bool) async throws(JetStreamError) -> FetchStream {
        throw .notConnected
    }

    func close(_ stream: FetchStream) async {}

    func messages(from stream: StreamName, for consumer: ConsumerName, options: PullOptions) -> AsyncThrowingStream<NatsMessage, any Error> {
        let preparedMessages = preparedMessages
        let outcome = outcome
        return AsyncThrowingStream<NatsMessage, any Error> { continuation in
            Task {
                for message in preparedMessages {
                    continuation.yield(message)
                }
                switch outcome {
                case .none: continuation.finish()
                case .typed(let typed): continuation.finish(throwing: typed)
                case .foreign(let foreign): continuation.finish(throwing: foreign)
                }
            }
        }
    }

    func ack(_ message: NatsMessage) {}
    func acknowledge(replies: [[UInt8]]) {}
}

private final class RecordingMessageHandler: DXMessageHandler, @unchecked Sendable {

    typealias Message = NatsMessage
    typealias Failure = JetStreamError

    private(set) var received: [NatsMessage] = []
    private(set) var errors: [JetStreamError] = []

    func receive(_ message: NatsMessage) async {
        received.append(message)
    }

    func receive(error: JetStreamError) async {
        errors.append(error)
    }
}

private func waitForMessages(handler: RecordingMessageHandler, atLeast count: Int) async {
    for _ in 0..<200 {
        if handler.received.count >= count { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func waitForError(handler: RecordingMessageHandler) async {
    for _ in 0..<200 {
        if !handler.errors.isEmpty { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
