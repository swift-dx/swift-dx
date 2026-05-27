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

public protocol JetStreamConsumerAdmin: Sendable {

    func ensure(_ consumer: ConsumerName, on stream: StreamName, configuration: ConsumerConfiguration) async throws(JetStreamError)
    func ensure(_ consumer: ConsumerName, on stream: StreamName) async throws(JetStreamError)
    func ensure(_ consumer: ConsumerName, on stream: StreamName, ackWait: TimeSpan) async throws(JetStreamError)
}

extension JetStreamConsumerAdmin {

    public func ensure(_ consumer: ConsumerName, on stream: StreamName) async throws(JetStreamError) {
        try await ensure(consumer, on: stream, configuration: .standard())
    }

    public func ensure(_ consumer: ConsumerName, on stream: StreamName, ackWait: TimeSpan) async throws(JetStreamError) {
        var configuration = ConsumerConfiguration.standard()
        configuration.ackWait = ackWait
        try await ensure(consumer, on: stream, configuration: configuration)
    }
}
