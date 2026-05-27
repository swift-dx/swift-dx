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
import Tracing
@testable import DXJetStream

@Suite
struct TracePropagationTests {

    @Test
    func injectWithTopLevelContext_returnsEmptyWithNoOpTracer() {
        let headers = TracePropagation.inject(ServiceContext.topLevel)
        #expect(headers.isEmpty)
    }

    @Test
    func injectCurrent_returnsEmptyWhenNoContextSet() {
        let headers = TracePropagation.injectCurrent()
        #expect(headers.isEmpty)
    }

    @Test
    func extractEmptyHeaders_returnsContextWithoutCrashing() {
        let context = TracePropagation.extract([])
        _ = context
    }

    @Test
    func extractWithSomeHeaders_returnsContextWithoutCrashing() {
        let headers = [
            NatsHeader(name: "traceparent", value: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"),
            NatsHeader(name: "Nats-Msg-Id", value: "42"),
        ]
        let context = TracePropagation.extract(headers)
        _ = context
    }

    @Test
    func headerInjector_appendsSingleEntryToCarrier() {
        let injector = TracePropagation.HeaderInjector()
        var carrier: [NatsHeader] = []
        injector.inject("value-a", forKey: "header-a", into: &carrier)
        #expect(carrier.count == 1)
        #expect(carrier[0].name == "header-a")
        #expect(carrier[0].value == "value-a")
    }

    @Test
    func headerInjector_preservesOrderAcrossInjects() {
        let injector = TracePropagation.HeaderInjector()
        var carrier: [NatsHeader] = []
        injector.inject("first", forKey: "k1", into: &carrier)
        injector.inject("second", forKey: "k2", into: &carrier)
        injector.inject("third", forKey: "k3", into: &carrier)
        #expect(carrier.count == 3)
        #expect(carrier[0].name == "k1")
        #expect(carrier[1].name == "k2")
        #expect(carrier[2].name == "k3")
    }

    @Test
    func headerExtractor_findsMatchingHeader() {
        let extractor = TracePropagation.HeaderExtractor()
        let headers = [
            NatsHeader(name: "traceparent", value: "abc"),
            NatsHeader(name: "tracestate", value: "def"),
        ]
        let result = extractor.extract(key: "traceparent", from: headers)
        #expect(result == "abc")
    }

    @Test
    func headerExtractor_returnsNilForMissingKey() {
        let extractor = TracePropagation.HeaderExtractor()
        let headers = [NatsHeader(name: "Foo", value: "bar")]
        let result = extractor.extract(key: "missing", from: headers)
        #expect(result == nil)
    }

    @Test
    func headerExtractor_isCaseSensitive() {
        let extractor = TracePropagation.HeaderExtractor()
        let headers = [NatsHeader(name: "Traceparent", value: "abc")]
        let result = extractor.extract(key: "traceparent", from: headers)
        #expect(result == nil)
    }

    @Test
    func headerExtractor_returnsFirstMatchOnDuplicateNames() {
        let extractor = TracePropagation.HeaderExtractor()
        let headers = [
            NatsHeader(name: "foo", value: "first"),
            NatsHeader(name: "foo", value: "second"),
        ]
        let result = extractor.extract(key: "foo", from: headers)
        #expect(result == "first")
    }

    @Test
    func lookupHeader_returnsFoundForMatch() {
        let headers = [NatsHeader(name: "foo", value: "bar")]
        switch lookupHeader(named: "foo", in: headers) {
        case .found(let value): #expect(value == "bar")
        case .notFound: Issue.record("expected to find 'foo' header")
        }
    }

    @Test
    func lookupHeader_returnsNotFoundForMissing() {
        let headers = [NatsHeader(name: "foo", value: "bar")]
        switch lookupHeader(named: "missing", in: headers) {
        case .found: Issue.record("did not expect to find 'missing' header")
        case .notFound: break
        }
    }

    @Test
    func lookupHeader_returnsNotFoundForEmptyList() {
        switch lookupHeader(named: "anything", in: []) {
        case .found: Issue.record("did not expect any match on empty list")
        case .notFound: break
        }
    }
}
