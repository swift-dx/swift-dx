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
struct PublishAckTests {

    @Test
    func pubAck_parsesSequenceNumber() throws {
        let payload = Array(#"{"stream":"S","seq":42,"duplicate":false}"#.utf8)
        let ack = try PublishAck.parse(payload)
        #expect(ack.sequence == 42)
        #expect(ack.duplicate == false)
    }

    @Test
    func pubAck_parsesDuplicateFlag() throws {
        let payload = Array(#"{"stream":"S","seq":7,"duplicate":true}"#.utf8)
        let ack = try PublishAck.parse(payload)
        #expect(ack.sequence == 7)
        #expect(ack.duplicate == true)
    }

    @Test
    func pubAck_throwsOnError() {
        let payload = Array(#"{"error":{"code":400,"description":"bad"}}"#.utf8)
        #expect(throws: JetStreamError.self) {
            _ = try PublishAck.parse(payload)
        }
    }

    @Test
    func pubAck_throwsOnShortPayload() {
        #expect(throws: JetStreamError.self) {
            _ = try PublishAck.parse([0x7b, 0x7d])
        }
    }

    @Test
    func pubAck_handlesLargeSequence() throws {
        let payload = Array(#"{"stream":"S","seq":18446744073709551610}"#.utf8)
        let ack = try PublishAck.parse(payload)
        #expect(ack.sequence == 18_446_744_073_709_551_610)
    }
}
