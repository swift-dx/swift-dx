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

import DXCore
import DXJetStream

struct OrderPublisher {

    let client: any JetStreamClient
    let subject: Subject

    func publish(orderId: String, payload: [UInt8]) async throws(JetStreamError) {
        let message = NatsOutgoingMessage(dedup: .dedupId(orderId), payload: payload)
        try await client.publish(to: subject, messages: [message])
    }
}

// Safe across threads in this example because the recording array is only
// written from a single Task. A real test would isolate the recorder behind
// a lock or actor.
final class RecordingClientMock: JetStreamClient, @unchecked Sendable {

    private(set) var publishedMessages: [(subject: String, messages: [NatsOutgoingMessage])] = []

    let inboxPrefix = "_INBOX.mock"

    func enqueue(to subject: Subject, payloads: [[UInt8]]) -> PublishHandle { fatalError("not used in this example") }
    func publish(to subject: Subject, payloads: [[UInt8]]) async throws(JetStreamError) {}
    func enqueue(to subject: Subject, messages: [NatsOutgoingMessage]) -> PublishHandle { fatalError("not used in this example") }
    func publish(to subject: Subject, messages: [NatsOutgoingMessage]) async throws(JetStreamError) {
        publishedMessages.append((subject: subject.value, messages: messages))
    }
    func fetch(from stream: StreamName, for consumer: ConsumerName, needsPayload: Bool) async throws(JetStreamError) -> FetchStream { fatalError("not used in this example") }
    func close(_ stream: FetchStream) async { fatalError("not used in this example") }
    func messages(from stream: StreamName, for consumer: ConsumerName, options: PullOptions) -> AsyncThrowingStream<NatsMessage, any Error> { fatalError("not used in this example") }
    func ack(_ message: NatsMessage) {}
    func acknowledge(replies: [[UInt8]]) {}
    func request(at subject: Subject, payload: [UInt8]) async throws(JetStreamError) -> NatsMessage { fatalError("not used in this example") }
    func ensure(_ stream: StreamName, subject: Subject, storage: StorageMode) async throws(JetStreamError) {}
    func delete(_ stream: StreamName) async throws(JetStreamError) {}
    func ensure(_ consumer: ConsumerName, on stream: StreamName, configuration: ConsumerConfiguration) async throws(JetStreamError) {}
    func close() async {}
}

func runUnitTestStylePattern() async throws {
    print("--- unit test style: mock client, no broker required ---")
    let mock = RecordingClientMock()
    let publisher = OrderPublisher(client: mock, subject: try Subject("orders.created"))

    try await publisher.publish(orderId: "order-1", payload: Array("first".utf8))
    try await publisher.publish(orderId: "order-2", payload: Array("second".utf8))

    print("captured \(mock.publishedMessages.count) publish calls:")
    for (subject, messages) in mock.publishedMessages {
        for message in messages {
            let displayId: String
            switch message.dedup {
            case .noDedup: displayId = "<none>"
            case .dedupId(let id): displayId = id
            }
            print("  subject=\(subject) id=\(displayId) payload=\(String(decoding: message.payload, as: UTF8.self))")
        }
    }
}

func runIntegrationStylePattern() async throws {
    print("--- integration test style: real broker, real publish ---")
    let configuration = JetStreamConfiguration(endpoint: NatsEndpoint(host: "localhost", port: 4222))
    try await JetStream.withClient(configuration) { client in
        let stream = try StreamName("EXAMPLE_INTEGRATION_\(UInt64.random(in: 0...UInt64.max))")
        let subject = try Subject("example.integration.orders")
        let consumer = try ConsumerName("example_integration_consumer")
        try await client.ensure(stream, subject: subject)
        try await client.ensure(consumer, on: stream, ackWait: .seconds(30))

        let publisher = OrderPublisher(client: client, subject: subject)
        try await publisher.publish(orderId: "real-1", payload: Array("real-first".utf8))
        try await publisher.publish(orderId: "real-2", payload: Array("real-second".utf8))

        let fetch = try await client.fetch(from: stream, for: consumer, needsPayload: true)
        let result = try await fetch.requestAndAwait(batch: 2, expires: .seconds(5), wait: .fill)
        await client.close(fetch)

        for payload in result.payloads {
            print("  fetched: \(String(decoding: payload, as: UTF8.self))")
        }
        client.acknowledge(replies: result.replies)

        try await client.delete(stream)
    }
}

try await runUnitTestStylePattern()
try await runIntegrationStylePattern()
