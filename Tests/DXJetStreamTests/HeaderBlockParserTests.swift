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
struct HeaderBlockParserTests {

    @Test
    func emptyBytes_returnsEmpty() {
        let bytes: [UInt8] = []
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.isEmpty)
    }

    @Test
    func versionLineOnly_returnsEmpty() {
        let bytes = Array("NATS/1.0\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.isEmpty)
    }

    @Test
    func singleHeader_returnsOneEntry() {
        let bytes = Array("NATS/1.0\r\nFoo: bar\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.count == 1)
        #expect(headers[0].name == "Foo")
        #expect(headers[0].value == "bar")
    }

    @Test
    func multipleHeaders_preservesOrder() {
        let bytes = Array("NATS/1.0\r\nFoo: bar\r\nBaz: qux\r\nNats-Msg-Id: 42\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.count == 3)
        #expect(headers[0].name == "Foo")
        #expect(headers[0].value == "bar")
        #expect(headers[1].name == "Baz")
        #expect(headers[1].value == "qux")
        #expect(headers[2].name == "Nats-Msg-Id")
        #expect(headers[2].value == "42")
    }

    @Test
    func statusLineWithCode_skipsVersionLineCorrectly() {
        let bytes = Array("NATS/1.0 100\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.isEmpty)
    }

    @Test
    func statusLineWithCodeAndHeaders_returnsHeadersOnly() {
        let bytes = Array("NATS/1.0 100 OK\r\nFoo: bar\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.count == 1)
        #expect(headers[0].name == "Foo")
        #expect(headers[0].value == "bar")
    }

    @Test
    func missingSpaceAfterColon_stillParses() {
        let bytes = Array("NATS/1.0\r\nFoo:bar\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.count == 1)
        #expect(headers[0].name == "Foo")
        #expect(headers[0].value == "bar")
    }

    @Test
    func emptyValue_returnsEmptyStringValue() {
        let bytes = Array("NATS/1.0\r\nFoo: \r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.count == 1)
        #expect(headers[0].name == "Foo")
        #expect(headers[0].value == "")
    }

    @Test
    func traceparentStyleHeader_roundTrips() {
        let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        let bytes = Array("NATS/1.0\r\ntraceparent: \(traceparent)\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        #expect(headers.count == 1)
        #expect(headers[0].name == "traceparent")
        #expect(headers[0].value == traceparent)
    }

    @Test
    func byteBufferViewVariant_matchesArrayVariant() {
        var buffer = ByteBuffer()
        buffer.writeString("NATS/1.0\r\nFoo: bar\r\nBaz: qux\r\n\r\n")
        let headersFromView = HeaderBlockParser.parse(view: buffer.readableBytesView, from: buffer.readerIndex, length: buffer.readableBytes)
        let headersFromArray = HeaderBlockParser.parse(Array("NATS/1.0\r\nFoo: bar\r\nBaz: qux\r\n\r\n".utf8))
        #expect(headersFromView.count == headersFromArray.count)
        for index in 0..<headersFromView.count {
            #expect(headersFromView[index].name == headersFromArray[index].name)
            #expect(headersFromView[index].value == headersFromArray[index].value)
        }
    }

    @Test
    func truncatedHeader_doesNotCrash() {
        let bytes = Array("NATS/1.0\r\nFoo: bar".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        _ = headers
    }

    @Test
    func headerWithoutColon_terminatesGracefully() {
        let bytes = Array("NATS/1.0\r\nNoColonHere\r\n\r\n".utf8)
        let headers = HeaderBlockParser.parse(bytes)
        _ = headers
    }
}
