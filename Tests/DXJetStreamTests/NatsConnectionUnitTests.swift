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

import NIOCore
import NIOPosix
import Testing
@testable import DXJetStream

@Suite
struct NatsConnectionUnitTests {

    @Test
    func natsConnection_inboxPrefixIsUniquePerInstance() {
        let group = MultiThreadedEventLoopGroup.singleton
        let conn1 = JetStreamClientImpl(group: group)
        let conn2 = JetStreamClientImpl(group: group)
        #expect(conn1.inboxPrefix != conn2.inboxPrefix)
        #expect(conn1.inboxPrefix.hasPrefix("_INBOX."))
        #expect(conn2.inboxPrefix.hasPrefix("_INBOX."))
    }

    @Test
    func natsConnection_closeWithoutConnectIsSafe() async {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        await conn.close()
    }

    @Test
    func natsConnection_writeBytesNonBlockingDoesNothingWhenUnconnected() {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        conn.writeBytesNonBlocking([0x01, 0x02])
    }

    @Test
    func natsConnection_enqueueRegistersBarrier() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let subject = try Subject("test.subject")
        let payloads: [[UInt8]] = [[0x61], [0x62]]
        let handle = conn.enqueue(to: subject, payloads: payloads)
        let dispatched1 = conn.dispatchBarrierByRange(suffix: 1)
        let dispatched2 = conn.dispatchBarrierByRange(suffix: 2)
        #expect(dispatched1)
        #expect(dispatched2)
        try await handle.wait()
    }

    @Test
    func natsConnection_dispatchBarrierByRangeReturnsFalseForUnknownSuffix() {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        #expect(!conn.dispatchBarrierByRange(suffix: 999))
    }

    @Test
    func natsConnection_dispatchFetchStreamReturnsFalseWhenSidUnknown() {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        #expect(!conn.dispatchFetchStream(sid: 42, subject: Array("s".utf8), reply: Array("r".utf8), headers: [], payload: [], status: .ok))
    }

    @Test
    func natsConnection_dispatchFetchBySidReturnsFalseWhenSidUnknown() {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        #expect(!conn.dispatchFetchBySid(sid: 42, subject: Array("s".utf8), reply: Array("r".utf8), headers: [], payload: [], status: .ok))
    }

    @Test
    func natsConnection_fetchNeedsPayloadReturnsFalseForUnknownSid() {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        #expect(!conn.fetchNeedsPayload(sid: 42))
    }

    @Test
    func natsConnection_enqueueProducesUniqueSuffixRangesAcrossCalls() async throws {
        let conn = JetStreamClientImpl(group: MultiThreadedEventLoopGroup.singleton)
        let subject = try Subject("test.subject")
        let handle1 = conn.enqueue(to: subject, payloads: [[0x01], [0x02]])
        let handle2 = conn.enqueue(to: subject, payloads: [[0x03], [0x04]])
        #expect(conn.dispatchBarrierByRange(suffix: 1))
        #expect(conn.dispatchBarrierByRange(suffix: 2))
        #expect(conn.dispatchBarrierByRange(suffix: 3))
        #expect(conn.dispatchBarrierByRange(suffix: 4))
        try await handle1.wait()
        try await handle2.wait()
    }
}
