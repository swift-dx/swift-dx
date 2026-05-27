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
import Testing
@testable import DXJetStream

@Suite
struct FrameBuilderPublishTests {

    @Test
    func publishWithIds_usesUserProvidedMessageIdsVerbatim() {
        let messages: [NatsOutgoingMessage] = [
            NatsOutgoingMessage(dedup: .dedupId("order-2026-001"), payload: Array("a".utf8)),
            NatsOutgoingMessage(dedup: .dedupId("order-2026-002"), payload: Array("b".utf8)),
        ]
        let buf = FrameBuilder.buildPublishBatchWithIds(
            allocator: ByteBufferAllocator(),
            subject: "orders",
            inboxPrefixBytes: Array("_INBOX.x".utf8),
            messages: messages,
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        #expect(text.contains("Nats-Msg-Id: order-2026-001"))
        #expect(text.contains("Nats-Msg-Id: order-2026-002"))
    }

    @Test
    func pullRequestFrame_endsWithCRLF() {
        let frame = FrameBuilder.buildPullRequest(pubSubject: "$JS.API", inbox: "_INBOX.x.1", batch: 5, expiresNanos: 1_000_000_000)
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text.hasSuffix("\r\n"))
        #expect(text.contains("{\"batch\":5,\"expires\":1000000000}"))
    }

    @Test
    func singleRequestFrame_includesPayloadLength() {
        let payload: [UInt8] = Array("ping".utf8)
        let frame = FrameBuilder.buildSingleRequest(subject: "$JS.X", reply: "_INBOX.r.1", payload: payload)
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text.hasPrefix("PUB $JS.X _INBOX.r.1 4\r\n"))
        #expect(text.hasSuffix("ping\r\n"))
    }

    @Test
    func ackBatch_emitsOnePublishAckPerReply() {
        let buf = FrameBuilder.buildAckBatch(allocator: ByteBufferAllocator(), replies: [Array("a.1".utf8), Array("a.2".utf8), Array("a.3".utf8)])
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        #expect(text == "PUB a.1 4\r\n+ACK\r\nPUB a.2 4\r\n+ACK\r\nPUB a.3 4\r\n+ACK\r\n")
    }
}
