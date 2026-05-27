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
struct JetStreamConsumerAdminExtensionTests {

    @Test
    func ensureWithoutArgs_routesThroughStandardConfiguration() async throws {
        let mock = RecordingConsumerAdmin()
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        try await mock.ensure(consumer, on: stream)
        #expect(mock.recordedEnsures.count == 1)
        let recorded = mock.recordedEnsures[0]
        #expect(recorded.configuration == .standard())
    }

    @Test
    func ensureWithAckWait_overridesOnlyAckWaitField() async throws {
        let mock = RecordingConsumerAdmin()
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        try await mock.ensure(consumer, on: stream, ackWait: .seconds(45))
        #expect(mock.recordedEnsures.count == 1)
        let recorded = mock.recordedEnsures[0]
        #expect(recorded.configuration.ackWait == .seconds(45))
        #expect(recorded.configuration.ackPolicy == ConsumerConfiguration.standard().ackPolicy)
        #expect(recorded.configuration.maxAckPending == ConsumerConfiguration.standard().maxAckPending)
    }

    @Test
    func ensureWithConfiguration_passesValueVerbatim() async throws {
        let mock = RecordingConsumerAdmin()
        let stream = try StreamName("ORDERS")
        let consumer = try ConsumerName("workers")
        let filter = SubjectMatch.pattern(try Subject("orders.created.*"))
        let configuration = ConsumerConfiguration(
            ackWait: .seconds(120),
            ackPolicy: .explicit,
            maxAckPending: 5_000,
            subjectFilter: filter,
            deliveryAttemptLimit: .max(3)
        )
        try await mock.ensure(consumer, on: stream, configuration: configuration)
        #expect(mock.recordedEnsures.count == 1)
        let recorded = mock.recordedEnsures[0]
        #expect(recorded.configuration == configuration)
        #expect(recorded.consumer == consumer)
        #expect(recorded.stream == stream)
    }
}

private final class RecordingConsumerAdmin: JetStreamConsumerAdmin, @unchecked Sendable {

    struct Record: Sendable {

        let consumer: ConsumerName
        let stream: StreamName
        let configuration: ConsumerConfiguration
    }

    private(set) var recordedEnsures: [Record] = []

    func ensure(_ consumer: ConsumerName, on stream: StreamName, configuration: ConsumerConfiguration) async throws(JetStreamError) {
        recordedEnsures.append(Record(consumer: consumer, stream: stream, configuration: configuration))
    }
}
