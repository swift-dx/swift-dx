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
import Foundation
import Testing

@Suite("ClickHouseService unit surface")
struct ClickHouseServiceUnitTests {

    @Test("Configuration requires at least one endpoint via assertion")
    func configurationEndpointsNonEmpty() {
        let configuration = ClickHouseConfiguration(
            endpoints: [ClickHouseEndpoint(host: "127.0.0.1", port: 9000)]
        )
        #expect(configuration.endpoints.count == 1)
        #expect(configuration.user == "default")
        #expect(configuration.database == "default")
        #expect(configuration.shutdownGracePeriod == .seconds(30))
    }

    @Test("Configuration host/port convenience init")
    func configurationHostPortInit() {
        let configuration = ClickHouseConfiguration(
            host: "ch.example.test",
            port: 9000,
            user: "service",
            password: "secret",
            database: "analytics"
        )
        #expect(configuration.endpoints == [ClickHouseEndpoint(host: "ch.example.test", port: 9000)])
        #expect(configuration.user == "service")
        #expect(configuration.password == "secret")
        #expect(configuration.database == "analytics")
    }

    @Test("Service init surfaces typed connection failure for unreachable host")
    func initFailsForUnreachableHost() async {
        let configuration = ClickHouseConfiguration(
            host: "127.0.0.1",
            port: 1,
            shutdownGracePeriod: .milliseconds(50)
        )
        do {
            _ = try await ClickHouseService(configuration: configuration)
            Issue.record("expected ClickHouseError from unreachable host")
        } catch {
            switch error {
            case .connectionFailed, .socketIOFailed, .reconnectExhausted, .endpointsExhausted:
                break
            default:
                Issue.record("unexpected ClickHouseError case: \(error)")
            }
        }
    }
}
