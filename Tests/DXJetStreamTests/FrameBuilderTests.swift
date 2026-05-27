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
struct FrameBuilderTests {

    @Test
    func frameBuilder_buildSubscribeProducesValidFrame() {
        let frame = FrameBuilder.buildSubscribe(inbox: "_INBOX.abc.*", sid: 7)
        #expect(String(decoding: frame, as: UTF8.self) == "SUB _INBOX.abc.* 7\r\n")
    }

    @Test
    func frameBuilder_buildUnsubscribeProducesValidFrame() {
        let frame = FrameBuilder.buildUnsubscribe(sid: 42)
        #expect(String(decoding: frame, as: UTF8.self) == "UNSUB 42\r\n")
    }

    @Test
    func frameBuilder_buildPullRequestEncodesBatchAndExpires() {
        let frame = FrameBuilder.buildPullRequest(pubSubject: "$JS.API.X", inbox: "_INBOX.r.1", batch: 100, expiresNanos: 5_000_000_000)
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text.hasPrefix("PUB $JS.API.X _INBOX.r.1 "))
        #expect(text.contains("{\"batch\":100,\"expires\":5000000000}"))
        #expect(text.hasSuffix("\r\n"))
    }

    @Test
    func frameBuilder_anonymousConnectIncludesExpectedFields() {
        let bytes = FrameBuilder.buildAnonymousConnect()
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("CONNECT "))
        #expect(text.contains("\"lang\":\"swift-dx\""))
        #expect(text.contains("\"headers\":true"))
        #expect(text.contains("\"no_responders\":true"))
        #expect(text.hasSuffix("\r\nPING\r\n"))
    }


    @Test
    func frameBuilder_decimalLengthHandlesZero() {
        #expect(FrameBuilder.decimalLength(0) == 1)
        #expect(FrameBuilder.decimalLength(9) == 1)
        #expect(FrameBuilder.decimalLength(10) == 2)
        #expect(FrameBuilder.decimalLength(99) == 2)
        #expect(FrameBuilder.decimalLength(100) == 3)
    }

    @Test
    func frameBuilder_base36LengthHandlesZero() {
        #expect(FrameBuilder.base36Length(0) == 1)
        #expect(FrameBuilder.base36Length(35) == 1)
        #expect(FrameBuilder.base36Length(36) == 2)
    }
}
