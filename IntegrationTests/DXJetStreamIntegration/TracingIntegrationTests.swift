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
import Tracing
@testable import DXJetStream

extension IntegrationRoot {

    @Suite struct TracingIntegration {

        private static let installedInstrument: Void = {
            InstrumentationSystem.bootstrap(TraceTestInstrument())
            return ()
        }()

        @Test
        func tracePropagation_carriesContextHeaderEndToEnd() async throws {
            _ = Self.installedInstrument
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("trace")
            let subject = try NatsTestEnvironment.uniqueSubject("trace")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("trace")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let producerTraceID = "trace-\(NatsTestEnvironment.uniqueSuffix())"
            var producerContext = ServiceContext.topLevel
            producerContext.traceTestID = producerTraceID
            try await ServiceContext.$current.withValue(producerContext) {
                try await conn.publish(to: subject, payloads: [Array("traced-payload".utf8)])
            }

            let fetchStream = try await conn.fetch(from: stream, for: consumer, needsPayload: true)
            let result = try await fetchStream.requestAndAwait(batch: 1, expires: .seconds(5), wait: .fill)
            await conn.close(fetchStream)

            #expect(result.replies.count == 1)
            #expect(result.headers.count == 1)
            let inboundHeaders = result.headers[0]
            var foundValue = ""
            var foundAny = false
            for header in inboundHeaders where header.name == TraceTestInstrument.headerName {
                foundValue = header.value
                foundAny = true
                break
            }
            #expect(foundAny, "expected '\(TraceTestInstrument.headerName)' header on the inbound message; got headers: \(inboundHeaders)")
            #expect(foundValue == producerTraceID)

            var extracted = ServiceContext.topLevel
            InstrumentationSystem.instrument.extract(inboundHeaders, into: &extracted, using: NatsHeaderExtractorForTest())
            #expect(extracted.traceTestID == producerTraceID)

            try await conn.delete(stream)
        }

        @Test
        func tracePropagation_carriesContextOnPublishMessagesPath() async throws {
            _ = Self.installedInstrument
            let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
            try await conn.connect(endpoint: NatsTestEnvironment.endpoint)
            defer { Task { await conn.close() } }

            let stream = try NatsTestEnvironment.uniqueStreamName("tracemsgs")
            let subject = try NatsTestEnvironment.uniqueSubject("tracemsgs")
            let consumer = try NatsTestEnvironment.uniqueConsumerName("tracemsgs")
            try await conn.ensure(stream, subject: subject)
            try await conn.ensure(consumer, on: stream, ackWait: .seconds(30))

            let producerTraceID = "tracemsgs-\(NatsTestEnvironment.uniqueSuffix())"
            var producerContext = ServiceContext.topLevel
            producerContext.traceTestID = producerTraceID
            try await ServiceContext.$current.withValue(producerContext) {
                let message = NatsOutgoingMessage(
                    dedup: .dedupId("trace-msg-1"),
                    headers: [NatsHeader(name: "X-Custom", value: "value-1")],
                    payload: Array("payload".utf8)
                )
                try await conn.publish(to: subject, messages: [message])
            }

            let fetchStream = try await conn.fetch(from: stream, for: consumer, needsPayload: true)
            let result = try await fetchStream.requestAndAwait(batch: 1, expires: .seconds(5), wait: .fill)
            await conn.close(fetchStream)

            #expect(result.headers.count == 1)
            let receivedHeaders = result.headers[0]
            let traceHeader = receivedHeaders.first { $0.name == TraceTestInstrument.headerName }
            #expect(traceHeader != nil)
            try await conn.delete(stream)
        }
    }
}

struct TraceTestInstrument: Instrument {

    static let headerName = "swiftdx-test-trace-id"

    func inject<Carrier, Inject>(_ context: ServiceContext, into carrier: inout Carrier, using injector: Inject) where Inject: Injector, Carrier == Inject.Carrier {
        guard let traceID = context.traceTestID else { return }
        injector.inject(traceID, forKey: Self.headerName, into: &carrier)
    }

    func extract<Carrier, Extract>(_ carrier: Carrier, into context: inout ServiceContext, using extractor: Extract) where Extract: Extractor, Carrier == Extract.Carrier {
        guard let traceID = extractor.extract(key: Self.headerName, from: carrier) else { return }
        context.traceTestID = traceID
    }
}

struct NatsHeaderExtractorForTest: Extractor {

    typealias Carrier = [NatsHeader]

    func extract(key: String, from carrier: [NatsHeader]) -> String? {
        for header in carrier where header.name == key {
            return header.value
        }
        return nil
    }
}

private enum TraceTestIDKey: ServiceContextKey {

    typealias Value = String
}

extension ServiceContext {

    var traceTestID: String? {
        get { self[TraceTestIDKey.self] }
        set { self[TraceTestIDKey.self] = newValue }
    }
}
