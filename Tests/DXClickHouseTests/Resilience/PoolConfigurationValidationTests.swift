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

// A structurally-invalid pool configuration (max-size below one, an
// inverted min/max pair, a negative minimum, or no endpoints) must
// surface a typed `Failure.invalidConfiguration` at construction. The
// original implementation used `precondition`, which traps and takes the
// whole host process down — unacceptable for a high-availability server
// where the pool size may be computed from configuration or environment
// and could legitimately come out wrong. The bound endpoint is never
// connected to: validation throws before any socket is opened.
@Suite("Connection pool rejects invalid configuration without crashing")
struct PoolConfigurationValidationTests {

    private static let endpoint = ClickHouseEndpoint(host: "127.0.0.1", port: 1)

    private func expectInvalidConfiguration(_ configuration: ClickHouseConnectionPool.Configuration) async {
        await #expect(throws: ClickHouseConnectionPool.Failure.self) {
            _ = try await ClickHouseConnectionPool(configuration: configuration)
        }
    }

    @Test("maxConnections below one is rejected, not trapped")
    func zeroMaxConnections() async {
        await expectInvalidConfiguration(
            .init(endpoints: [Self.endpoint], minConnections: 0, maxConnections: 0)
        )
    }

    @Test("minConnections greater than maxConnections is rejected, not trapped")
    func invertedMinMax() async {
        await expectInvalidConfiguration(
            .init(endpoints: [Self.endpoint], minConnections: 5, maxConnections: 2)
        )
    }

    @Test("an empty endpoint list is rejected, not trapped")
    func emptyEndpoints() async {
        await expectInvalidConfiguration(
            .init(endpoints: [], minConnections: 1, maxConnections: 4)
        )
    }

    @Test("the typed failure names the offending field")
    func failureCarriesReason() async {
        do {
            _ = try await ClickHouseConnectionPool(
                configuration: .init(endpoints: [Self.endpoint], minConnections: 0, maxConnections: 0)
            )
            Issue.record("expected an invalidConfiguration failure")
        } catch {
            guard case .invalidConfiguration(let reason) = error else {
                Issue.record("expected invalidConfiguration, got \(error)")
                return
            }
            #expect(reason.contains("maxConnections"))
        }
    }
}
