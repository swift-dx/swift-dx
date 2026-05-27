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

public protocol JetStreamPublisher: Sendable {
    func publish(to subject: Subject, payloads: [[UInt8]]) async throws(JetStreamError)
    func publish(to subject: Subject, messages: [NatsOutgoingMessage]) async throws(JetStreamError)
    func enqueue(to subject: Subject, payloads: [[UInt8]]) -> PublishHandle
    func enqueue(to subject: Subject, messages: [NatsOutgoingMessage]) -> PublishHandle
}
