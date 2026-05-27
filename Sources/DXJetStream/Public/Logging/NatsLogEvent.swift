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

public enum NatsLogEvent: Sendable {

    case connecting(endpoint: NatsEndpoint)
    case connected(endpoint: NatsEndpoint)
    case disconnected
    case handshakeReceivedInfo
    case handshakeAuthenticatedSent
    case handshakeAnonymousSent
    case handshakeCompleted
    case handshakeFailed(reason: String)
    case publishStarted(traceId: NatsTraceId, subject: String, count: Int)
    case publishAcked(traceId: NatsTraceId)
    case fetchOpened(stream: String, consumer: String)
    case fetchRequestSent(traceId: NatsTraceId, batch: Int)
    case fetchResultReceived(traceId: NatsTraceId, replies: Int)
    case fetchStatus(traceId: NatsTraceId, code: UInt16)
    case fetchClosed
    case streamEnsured(name: String)
    case streamDeleted(name: String)
    case consumerEnsured(stream: String, consumer: String)
    case errorRaised(reason: String)
}
