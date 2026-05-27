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
struct NatsEndpointTests {

    @Test
    func endpoint_defaultPortIs4222() {
        let endpoint = NatsEndpoint(host: "localhost")
        #expect(endpoint.host == "localhost")
        #expect(endpoint.port == 4222)
    }

    @Test
    func endpoint_customPort() {
        let endpoint = NatsEndpoint(host: "10.0.0.1", port: 5222)
        #expect(endpoint.host == "10.0.0.1")
        #expect(endpoint.port == 5222)
    }
}
