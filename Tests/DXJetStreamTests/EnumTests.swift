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
struct EnumTests {

    @Test
    func replyAddress_equality() {
        #expect(ReplyAddress.none == ReplyAddress.none)
        #expect(ReplyAddress.subject("a") == ReplyAddress.subject("a"))
        #expect(ReplyAddress.subject("a") != ReplyAddress.subject("b"))
        #expect(ReplyAddress.none != ReplyAddress.subject(""))
    }

    @Test
    func natsMessageStatus_equality() {
        #expect(NatsMessageStatus.ok == NatsMessageStatus.ok)
        #expect(NatsMessageStatus.code(404) == NatsMessageStatus.code(404))
        #expect(NatsMessageStatus.code(404) != NatsMessageStatus.code(408))
        #expect(NatsMessageStatus.ok != NatsMessageStatus.code(0))
    }

    @Test
    func fetchWait_atLeastCarriesCount() {
        let wait = FetchWait.atLeast(5)
        if case .atLeast(let count) = wait {
            #expect(count == 5)
        } else {
            Issue.record("Expected atLeast case")
        }
    }

    @Test
    func fetchWait_caseEquality() {
        #expect(FetchWait.fill == FetchWait.fill)
        #expect(FetchWait.anyAvailable == FetchWait.anyAvailable)
        #expect(FetchWait.atLeast(3) == FetchWait.atLeast(3))
        #expect(FetchWait.atLeast(3) != FetchWait.atLeast(4))
    }

    @Test
    func storageMode_allCasesEqualThemselves() {
        #expect(StorageMode.file == StorageMode.file)
        #expect(StorageMode.memory == StorageMode.memory)
        #expect(StorageMode.file != StorageMode.memory)
    }

    @Test
    func ackPolicy_allCasesEqualThemselves() {
        #expect(AckPolicy.explicit == AckPolicy.explicit)
        #expect(AckPolicy.all == AckPolicy.all)
        #expect(AckPolicy.none == AckPolicy.none)
        #expect(AckPolicy.explicit != AckPolicy.all)
        #expect(AckPolicy.all != AckPolicy.none)
    }

    @Test
    func error_equality() {
        #expect(JetStreamError.notConnected == JetStreamError.notConnected)
        #expect(JetStreamError.publishTimedOut == JetStreamError.publishTimedOut)
        #expect(JetStreamError.invalidStreamName("a") == JetStreamError.invalidStreamName("a"))
        #expect(JetStreamError.invalidStreamName("a") != JetStreamError.invalidStreamName("b"))
        #expect(JetStreamError.fetchStatus(code: 404) == JetStreamError.fetchStatus(code: 404))
        #expect(JetStreamError.fetchStatus(code: 404) != JetStreamError.fetchStatus(code: 408))
        #expect(JetStreamError.notConnected != JetStreamError.publishTimedOut)
    }

    @Test
    func error_allPayloadCasesPreserveValue() {
        let cases: [JetStreamError] = [
            .invalidStreamName("s"),
            .invalidConsumerName("c"),
            .invalidSubject("subj"),
            .handshakeFailed(reason: "h"),
            .protocolError(reason: "p"),
            .serverError(reason: "srv"),
            .publishAckError(reason: "pa")
        ]
        for value in cases {
            #expect(value == value)
        }
    }
}
