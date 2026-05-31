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
@testable import DXJetStream

@Suite
struct FrameBuilderAckResponseTests {

    @Test
    func nakFrame_publishesNegativeAckToReply() {
        let frame = FrameBuilder.buildNak(reply: Array("$JS.ACK.s.c.1".utf8))
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text == "PUB $JS.ACK.s.c.1 4\r\n-NAK\r\n")
    }

    @Test
    func nakWithDelay_encodesDelayNanosecondsAsJSON() {
        let frame = FrameBuilder.buildNak(reply: Array("a.r".utf8), delayNanoseconds: 5_000_000_000)
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text == "PUB a.r 25\r\n-NAK {\"delay\":5000000000}\r\n")
    }

    @Test
    func termFrame_publishesTerminateToReply() {
        let frame = FrameBuilder.buildTerm(reply: Array("a.r".utf8))
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text == "PUB a.r 5\r\n+TERM\r\n")
    }

    @Test
    func termWithReason_appendsReasonAfterToken() {
        let frame = FrameBuilder.buildTerm(reply: Array("a.r".utf8), reason: "poison message")
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text == "PUB a.r 20\r\n+TERM poison message\r\n")
    }

    @Test
    func inProgressFrame_publishesWorkInProgressToReply() {
        let frame = FrameBuilder.buildInProgress(reply: Array("a.r".utf8))
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text == "PUB a.r 4\r\n+WPI\r\n")
    }
}
