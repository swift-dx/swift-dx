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
struct NameValidationTests {

    @Test
    func streamName_acceptsAlphanumericUnderscoreAndHyphen() throws {
        _ = try StreamName("MY_STREAM-01")
    }

    @Test
    func streamName_rejectsEmptyString() {
        #expect(throws: JetStreamError.invalidStreamName("")) {
            _ = try StreamName("")
        }
    }

    @Test
    func streamName_rejectsPeriod() {
        #expect(throws: JetStreamError.invalidStreamName("a.b")) {
            _ = try StreamName("a.b")
        }
    }

    @Test
    func streamName_rejectsWildcard() {
        #expect(throws: JetStreamError.invalidStreamName("a*")) {
            _ = try StreamName("a*")
        }
    }

    @Test
    func consumerName_acceptsAlphanumericUnderscoreAndHyphen() throws {
        _ = try ConsumerName("durable_consumer-1")
    }

    @Test
    func consumerName_rejectsSpace() {
        #expect(throws: JetStreamError.invalidConsumerName("a b")) {
            _ = try ConsumerName("a b")
        }
    }

    @Test
    func subject_acceptsTokens() throws {
        _ = try Subject("orders.created.v1")
    }

    @Test
    func subject_acceptsWildcards() throws {
        _ = try Subject("orders.*.v1")
        _ = try Subject("orders.>")
    }

    @Test
    func subject_acceptsSystemDollarPrefix() throws {
        _ = try Subject("$JS.API.STREAM.CREATE.ORDERS")
        _ = try Subject("$SYS.REQ.ACCOUNT")
    }

    @Test
    func subject_rejectsLeadingDot() {
        #expect(throws: JetStreamError.invalidSubject(".orders")) {
            _ = try Subject(".orders")
        }
    }

    @Test
    func subject_rejectsTrailingDot() {
        #expect(throws: JetStreamError.invalidSubject("orders.")) {
            _ = try Subject("orders.")
        }
    }

    @Test
    func subject_rejectsConsecutiveDots() {
        #expect(throws: JetStreamError.invalidSubject("orders..created")) {
            _ = try Subject("orders..created")
        }
    }

    @Test
    func subject_rejectsEmptyString() {
        #expect(throws: JetStreamError.invalidSubject("")) {
            _ = try Subject("")
        }
    }
}
