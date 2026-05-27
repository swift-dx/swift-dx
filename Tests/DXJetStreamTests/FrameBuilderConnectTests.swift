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
struct FrameBuilderConnectTests {

    @Test
    func buildAuthenticatedConnect_emitsConnectFrameWithJwtAndSignature() {
        let bytes = FrameBuilder.buildAuthenticatedConnect(jwt: "eyJhbGciOi.fake.jwt", signature: "abc123signature")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("CONNECT "))
        #expect(text.contains("\"jwt\":\"eyJhbGciOi.fake.jwt\""))
        #expect(text.contains("\"sig\":\"abc123signature\""))
        #expect(text.contains("\"lang\":\"swift-dx\""))
        #expect(text.contains("\"headers\":true"))
        #expect(text.hasSuffix("\r\nPING\r\n"))
    }

    @Test
    func buildAuthenticatedConnect_acceptsEmptyJwtAndSignature() {
        let bytes = FrameBuilder.buildAuthenticatedConnect(jwt: "", signature: "")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("CONNECT "))
        #expect(text.contains("\"jwt\":\"\""))
        #expect(text.contains("\"sig\":\"\""))
    }

    @Test
    func buildAnonymousConnect_emitsConnectFrameWithoutJwt() {
        let bytes = FrameBuilder.buildAnonymousConnect()
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("CONNECT "))
        #expect(!text.contains("\"jwt\""))
        #expect(!text.contains("\"sig\""))
        #expect(text.contains("\"lang\":\"swift-dx\""))
    }
}
