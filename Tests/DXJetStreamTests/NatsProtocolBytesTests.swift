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
struct NatsProtocolBytesTests {

    private func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    @Test
    func natsProtocol_opTokensDecodeToProtocolKeywords() {
        #expect(decode(NatsProtocolBytes.hpubOp) == "HPUB ")
        #expect(decode(NatsProtocolBytes.msgOp) == "MSG ")
        #expect(decode(NatsProtocolBytes.hmsgOp) == "HMSG ")
        #expect(decode(NatsProtocolBytes.infoOp) == "INFO ")
        #expect(decode(NatsProtocolBytes.errOp) == "-ERR")
    }

    @Test
    func natsProtocol_pingPongControlTokens() {
        #expect(decode(NatsProtocolBytes.pingControl) == "PI")
        #expect(decode(NatsProtocolBytes.pongControl) == "PO")
    }

    @Test
    func natsProtocol_pongResponseEndsWithCRLF() {
        #expect(decode(NatsProtocolBytes.pongResponse) == "PONG\r\n")
    }

    @Test
    func natsProtocol_pingResponseStartsWithCRLF() {
        #expect(decode(NatsProtocolBytes.pingResponse) == "\r\nPING\r\n")
    }

    @Test
    func natsProtocol_crlfTokenIsCarriageReturnLineFeed() {
        #expect(NatsProtocolBytes.crlf == [0x0d, 0x0a])
    }

    @Test
    func natsProtocol_doubleCrlfMarksEndOfHeaders() {
        #expect(decode(NatsProtocolBytes.doubleCrlf) == "\r\n\r\n")
    }

    @Test
    func natsProtocol_messageIdHeaderPrefixMatchesWireFormat() {
        #expect(decode(NatsProtocolBytes.messageIdHeaderPrefix) == "NATS/1.0\r\nNats-Msg-Id: ")
    }

    @Test
    func natsProtocol_nonceKeyMatchesWireField() {
        #expect(decode(NatsProtocolBytes.nonceKey) == "\"nonce\"")
    }
}
