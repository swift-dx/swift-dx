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
@testable import DXJetStream

@Suite
struct NatsLoggerTests {

    private func makeLogger() -> (NatsLogger, CapturingLogHandler) {
        let handler = CapturingLogHandler()
        let logger = Logger(label: "test", factory: { _ in handler })
        return (NatsLogger(logger), handler)
    }

    @Test
    func silent_dropsEmits() {
        let silent = NatsLogger.silent
        silent.emit(.disconnected)
        silent.emitError(.errorRaised(reason: "boom"))
    }

    @Test
    func standard_factoryReturnsConfiguredLogger() {
        let logger = NatsLogger.standard(label: "test.factory")
        logger.emit(.disconnected)
    }

    @Test
    func emit_respectsLogLevelFilter() {
        let (natsLogger, handler) = makeLogger()
        handler.logLevel = .error
        natsLogger.emit(.disconnected, level: .debug)
        #expect(handler.entries.isEmpty)
    }

    @Test
    func emit_connecting_rendersHostAndPortMetadata() {
        let (natsLogger, handler) = makeLogger()
        let endpoint = NatsEndpoint(host: "broker.example", port: 4222)
        natsLogger.emit(.connecting(endpoint: endpoint))
        #expect(handler.entries.count == 1)
        #expect(handler.entries[0].message == "connecting")
        #expect(handler.metadataString(at: 0, key: "host") == "broker.example")
        #expect(handler.metadataString(at: 0, key: "port") == "4222")
    }

    @Test
    func emit_connected_rendersHostAndPort() {
        let (natsLogger, handler) = makeLogger()
        let endpoint = NatsEndpoint(host: "broker.example", port: 4222)
        natsLogger.emit(.connected(endpoint: endpoint))
        #expect(handler.entries[0].message == "connected")
        #expect(handler.metadataString(at: 0, key: "host") == "broker.example")
    }

    @Test
    func emit_disconnected_emitsMessageWithEmptyMetadata() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.disconnected)
        #expect(handler.entries[0].message == "disconnected")
        #expect(handler.entries[0].metadata.isEmpty)
    }

    @Test
    func emit_handshakeReceivedInfo_emitsLabel() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.handshakeReceivedInfo)
        #expect(handler.entries[0].message == "handshake.info_received")
    }

    @Test
    func emit_handshakeAuthenticatedSent_emitsLabel() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.handshakeAuthenticatedSent)
        #expect(handler.entries[0].message == "handshake.authenticated_connect_sent")
    }

    @Test
    func emit_handshakeAnonymousSent_emitsLabel() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.handshakeAnonymousSent)
        #expect(handler.entries[0].message == "handshake.anonymous_connect_sent")
    }

    @Test
    func emit_handshakeCompleted_emitsLabel() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.handshakeCompleted)
        #expect(handler.entries[0].message == "handshake.completed")
    }

    @Test
    func emit_handshakeFailed_carriesReason() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.handshakeFailed(reason: "bad nonce"))
        #expect(handler.entries[0].message == "handshake.failed")
        #expect(handler.metadataString(at: 0, key: "reason") == "bad nonce")
    }

    @Test
    func emit_publishStarted_carriesTraceAndSubject() {
        let (natsLogger, handler) = makeLogger()
        let traceId = NatsTraceId(value: 7)
        natsLogger.emit(.publishStarted(traceId: traceId, subject: "orders.created", count: 3))
        #expect(handler.entries[0].message == "publish.batch_started")
        #expect(handler.metadataString(at: 0, key: "subject") == "orders.created")
        #expect(handler.metadataString(at: 0, key: "count") == "3")
    }

    @Test
    func emit_publishAcked_carriesTrace() {
        let (natsLogger, handler) = makeLogger()
        let traceId = NatsTraceId(value: 9)
        natsLogger.emit(.publishAcked(traceId: traceId))
        #expect(handler.entries[0].message == "publish.batch_acked")
    }

    @Test
    func emit_fetchOpened_carriesStreamAndConsumer() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.fetchOpened(stream: "ORDERS", consumer: "workers"))
        #expect(handler.entries[0].message == "fetch.opened")
        #expect(handler.metadataString(at: 0, key: "stream") == "ORDERS")
        #expect(handler.metadataString(at: 0, key: "consumer") == "workers")
    }

    @Test
    func emit_fetchRequestSent_carriesBatch() {
        let (natsLogger, handler) = makeLogger()
        let traceId = NatsTraceId(value: 11)
        natsLogger.emit(.fetchRequestSent(traceId: traceId, batch: 100))
        #expect(handler.entries[0].message == "fetch.request_sent")
        #expect(handler.metadataString(at: 0, key: "batch") == "100")
    }

    @Test
    func emit_fetchResultReceived_carriesReplyCount() {
        let (natsLogger, handler) = makeLogger()
        let traceId = NatsTraceId(value: 12)
        natsLogger.emit(.fetchResultReceived(traceId: traceId, replies: 50))
        #expect(handler.entries[0].message == "fetch.result_received")
        #expect(handler.metadataString(at: 0, key: "replies") == "50")
    }

    @Test
    func emit_fetchStatus_carriesCode() {
        let (natsLogger, handler) = makeLogger()
        let traceId = NatsTraceId(value: 13)
        natsLogger.emit(.fetchStatus(traceId: traceId, code: 404))
        #expect(handler.entries[0].message == "fetch.status")
        #expect(handler.metadataString(at: 0, key: "code") == "404")
    }

    @Test
    func emit_fetchClosed_emitsLabel() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.fetchClosed)
        #expect(handler.entries[0].message == "fetch.closed")
    }

    @Test
    func emit_streamEnsured_carriesName() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.streamEnsured(name: "ORDERS"))
        #expect(handler.entries[0].message == "stream.ensured")
        #expect(handler.metadataString(at: 0, key: "name") == "ORDERS")
    }

    @Test
    func emit_streamDeleted_carriesName() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.streamDeleted(name: "ORDERS"))
        #expect(handler.entries[0].message == "stream.deleted")
        #expect(handler.metadataString(at: 0, key: "name") == "ORDERS")
    }

    @Test
    func emit_consumerEnsured_carriesStreamAndConsumer() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.consumerEnsured(stream: "ORDERS", consumer: "workers"))
        #expect(handler.entries[0].message == "consumer.ensured")
        #expect(handler.metadataString(at: 0, key: "stream") == "ORDERS")
        #expect(handler.metadataString(at: 0, key: "consumer") == "workers")
    }

    @Test
    func emit_errorRaised_carriesReason() {
        let (natsLogger, handler) = makeLogger()
        natsLogger.emit(.errorRaised(reason: "connection reset"))
        #expect(handler.entries[0].message == "error")
        #expect(handler.metadataString(at: 0, key: "reason") == "connection reset")
    }

    @Test
    func emitError_alwaysRendersAtErrorLevel() {
        let (natsLogger, handler) = makeLogger()
        handler.logLevel = .warning
        natsLogger.emitError(.errorRaised(reason: "transport down"))
        #expect(handler.entries.count == 1)
        #expect(handler.entries[0].level == .error)
        #expect(handler.entries[0].message == "error")
    }
}
