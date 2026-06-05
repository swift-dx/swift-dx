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

import DXClickHouse
import Testing

// A ClickHouseConfiguration with no endpoints cannot dial a server — the
// client reads the first endpoint to connect. Building the endpoint list
// dynamically (service discovery, environment parsing) that resolves to
// an empty list is a recoverable application condition, so it must
// surface a typed error at construction rather than trapping the whole
// process. The single host/port convenience form always yields one
// endpoint and stays non-throwing.
@Suite("ClickHouseConfiguration rejects an empty endpoint list without crashing")
struct ConfigurationValidationTests {

    @Test("an empty endpoints list throws a typed configuration error")
    func emptyEndpointsThrows() {
        var caught: ClickHouseError?
        do {
            _ = try ClickHouseConfiguration(endpoints: [])
        } catch {
            caught = error
        }
        guard case .protocolError(let stage, _) = caught else {
            Issue.record("expected a protocolError, got \(String(describing: caught))")
            return
        }
        #expect(stage == "configuration")
    }

    @Test("a non-empty endpoints list builds successfully")
    func nonEmptyEndpointsBuilds() throws {
        let configuration = try ClickHouseConfiguration(
            endpoints: [
                ClickHouseEndpoint(host: "a", port: 9000),
                ClickHouseEndpoint(host: "b", port: 9000),
            ]
        )
        #expect(configuration.endpoints.count == 2)
    }

    @Test("the host/port convenience form needs no try and always has one endpoint")
    func hostPortFormIsNonThrowing() {
        let configuration = ClickHouseConfiguration(host: "127.0.0.1", port: 9000)
        #expect(configuration.endpoints == [ClickHouseEndpoint(host: "127.0.0.1", port: 9000)])
    }
}
