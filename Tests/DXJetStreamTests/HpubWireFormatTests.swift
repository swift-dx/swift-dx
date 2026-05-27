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
import NIOCore
@testable import DXJetStream

@Suite
struct HpubWireFormatTests {

    @Test
    func hpub_wireFormatExactBytes() {
        let messages: [NatsOutgoingMessage] = [
            NatsOutgoingMessage(dedup: .dedupId("msg-1"), payload: Array("hello".utf8)),
            NatsOutgoingMessage(dedup: .dedupId("msg-2"), payload: Array("world".utf8)),
        ]
        let buf = FrameBuilder.buildPublishBatchWithIds(
            allocator: ByteBufferAllocator(),
            subject: "test.subj",
            inboxPrefixBytes: Array("_INBOX.abc".utf8),
            messages: messages,
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        let expected =
            "HPUB test.subj _INBOX.abc.1 32 37\r\nNATS/1.0\r\nNats-Msg-Id: msg-1\r\n\r\nhello\r\n" +
            "HPUB test.subj _INBOX.abc.2 32 37\r\nNATS/1.0\r\nNats-Msg-Id: msg-2\r\n\r\nworld\r\n"
        #expect(text == expected)
    }

    @Test
    func hpub_hlenIncludesTrailingCrlfCrlf() {
        let messages = [NatsOutgoingMessage(dedup: .dedupId("abc"), payload: Array("x".utf8))]
        let buf = FrameBuilder.buildPublishBatchWithIds(
            allocator: ByteBufferAllocator(),
            subject: "s",
            inboxPrefixBytes: Array("i".utf8),
            messages: messages,
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        let headerSection = "NATS/1.0\r\nNats-Msg-Id: abc\r\n\r\n"
        #expect(text.contains(" \(headerSection.utf8.count) "))
    }

    @Test
    func hpub_emitsSingleUserHeader() {
        let messages = [
            NatsOutgoingMessage(
                dedup: .dedupId("msg-1"),
                headers: [NatsHeader(name: "X-Foo", value: "bar")],
                payload: Array("hello".utf8)
            ),
        ]
        let buf = FrameBuilder.buildPublishBatchWithIds(
            allocator: ByteBufferAllocator(),
            subject: "test.subj",
            inboxPrefixBytes: Array("_INBOX.abc".utf8),
            messages: messages,
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        let expected =
            "HPUB test.subj _INBOX.abc.1 44 49\r\nNATS/1.0\r\nNats-Msg-Id: msg-1\r\nX-Foo: bar\r\n\r\nhello\r\n"
        #expect(text == expected)
    }

    @Test
    func hpub_emitsMultipleUserHeadersInOrder() {
        let messages = [
            NatsOutgoingMessage(
                dedup: .dedupId("msg-1"),
                headers: [
                    NatsHeader(name: "X-Foo", value: "bar"),
                    NatsHeader(name: "X-Baz", value: "qux"),
                ],
                payload: Array("hello".utf8)
            ),
        ]
        let buf = FrameBuilder.buildPublishBatchWithIds(
            allocator: ByteBufferAllocator(),
            subject: "test.subj",
            inboxPrefixBytes: Array("_INBOX.abc".utf8),
            messages: messages,
            loSuffix: 1
        )
        let text = buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        let expected =
            "HPUB test.subj _INBOX.abc.1 56 61\r\nNATS/1.0\r\nNats-Msg-Id: msg-1\r\nX-Foo: bar\r\nX-Baz: qux\r\n\r\nhello\r\n"
        #expect(text == expected)
    }

    @Test
    func hpub_emptyHeadersListMatchesOriginalFormat() {
        let messagesNoHeaders = [
            NatsOutgoingMessage(dedup: .dedupId("msg-1"), payload: Array("hello".utf8)),
        ]
        let messagesEmptyHeaders = [
            NatsOutgoingMessage(dedup: .dedupId("msg-1"), headers: [], payload: Array("hello".utf8)),
        ]
        let allocator = ByteBufferAllocator()
        let bufA = FrameBuilder.buildPublishBatchWithIds(allocator: allocator, subject: "s", inboxPrefixBytes: Array("i".utf8), messages: messagesNoHeaders, loSuffix: 1)
        let bufB = FrameBuilder.buildPublishBatchWithIds(allocator: allocator, subject: "s", inboxPrefixBytes: Array("i".utf8), messages: messagesEmptyHeaders, loSuffix: 1)
        let textA = bufA.getString(at: bufA.readerIndex, length: bufA.readableBytes) ?? ""
        let textB = bufB.getString(at: bufB.readerIndex, length: bufB.readableBytes) ?? ""
        #expect(textA == textB)
    }
}
