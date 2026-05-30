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

// Shared scaffolding for the MultiEndpointFailover suites. Lives next
// to the test files so each suite can build its own endpoint mix from a
// single source of truth — the live broker reachable via the standard
// CH_INTEGRATION_* env vars, optionally combined with a synthetic
// always-unreachable endpoint at 127.0.0.1:1.
enum MultiEndpointFailoverSupport {

    static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    static var liveEndpoint: ClickHouseEndpoint {
        ClickHouseEndpoint(host: host, port: port)
    }

    // Synthetic always-unreachable endpoint. Port 1 is reserved (tcpmux)
    // and TCP connect attempts to it return ECONNREFUSED immediately on
    // every host we deploy on, which is the behaviour the failover
    // logic expects when an endpoint is down.
    static var unreachableEndpoint: ClickHouseEndpoint {
        ClickHouseEndpoint(host: "127.0.0.1", port: 1)
    }
}
