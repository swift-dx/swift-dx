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
struct FrameBuilderPlainPubTests {

    @Test
    func publishPlain_omitsHeadersAndUsesPubOp() {
        let buf = FrameBuilder.buildPublishBatchPlain(
            allocator: ByteBufferAllocator(),
            subject: "orders",
            inboxPrefixBytes: Array("_INBOX.abc".utf8),
            payloads: [Array("hello".utf8)],
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        #expect(text.hasPrefix("PUB orders _INBOX.abc.1 "))
        #expect(!text.contains("HPUB"))
        #expect(!text.contains("Nats-Msg-Id"))
        #expect(text.hasSuffix("hello\r\n"))
    }

    @Test
    func publishPlain_emitsConsecutiveReplySuffixes() {
        let buf = FrameBuilder.buildPublishBatchPlain(
            allocator: ByteBufferAllocator(),
            subject: "s",
            inboxPrefixBytes: Array("_INBOX.a".utf8),
            payloads: [Array("0".utf8), Array("1".utf8), Array("2".utf8)],
            loSuffix: 10
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        #expect(text.contains("_INBOX.a.a "))
        #expect(text.contains("_INBOX.a.b "))
        #expect(text.contains("_INBOX.a.c "))
    }

    @Test
    func publishPlain_endsEachMessageWithCRLF() {
        let buf = FrameBuilder.buildPublishBatchPlain(
            allocator: ByteBufferAllocator(),
            subject: "s",
            inboxPrefixBytes: Array("_INBOX.a".utf8),
            payloads: [Array("a".utf8), Array("b".utf8)],
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        let crlfPerMessage = 2
        let messages = 2
        #expect(text.components(separatedBy: "\r\n").count == messages * crlfPerMessage + 1)
    }
}
