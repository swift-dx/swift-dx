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
struct NatsMessageTests {

    @Test
    func natsMessage_initStoresAllFields() {
        let message = NatsMessage(
            subject: "orders.created",
            sid: 42,
            reply: .subject("_INBOX.x.1"),
            payload: [0x01, 0x02, 0x03],
            status: .code(404)
        )
        #expect(message.subject == "orders.created")
        #expect(message.sid == 42)
        #expect(message.payload == [0x01, 0x02, 0x03])
        if case .subject(let value) = message.reply {
            #expect(value == "_INBOX.x.1")
        } else {
            Issue.record("Expected reply.subject case")
        }
        if case .code(let value) = message.status {
            #expect(value == 404)
        } else {
            Issue.record("Expected status.code case")
        }
    }

    @Test
    func natsMessage_supportsNoReplyAndOkStatus() {
        let message = NatsMessage(
            subject: "no.reply",
            sid: 1,
            reply: .none,
            payload: [],
            status: .ok
        )
        if case .none = message.reply {} else {
            Issue.record("Expected reply.none case")
        }
        if case .ok = message.status {} else {
            Issue.record("Expected status.ok case")
        }
    }
}
