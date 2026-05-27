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

import DXJetStream

let configuration = JetStreamConfiguration(endpoint: NatsEndpoint(host: "localhost", port: 4222))

try await JetStream.withClient(configuration) { client in
    let stream = try StreamName("EXAMPLE")
    let subject = try Subject("example.events")
    let consumer = try ConsumerName("example_consumer")

    try await client.ensure(stream, subject: subject)
    try await client.ensure(consumer, on: stream, ackWait: .seconds(30))

    let payloads: [[UInt8]] = (0..<5).map { Array("hello-\($0)".utf8) }
    try await client.publish(to: subject, payloads: payloads)
    print("published \(payloads.count) messages")

    let fetch = try await client.fetch(from: stream, for: consumer, needsPayload: true)
    let result = try await fetch.requestAndAwait(batch: 5, expires: .seconds(5), wait: .fill)
    await client.close(fetch)

    for payload in result.payloads {
        print("received: \(String(decoding: payload, as: UTF8.self))")
    }
    client.acknowledge(replies: result.replies)

    try await client.delete(stream)
}
