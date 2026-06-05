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

import Logging
import ServiceLifecycle

// Long-running ClickHouse service for swift-service-lifecycle integration.
// Coexists with `ClickHouse.connect` / `ClickHouse.withClient` — both
// paths route through the same `ClickHouseClient` so on-the-wire behaviour
// is identical.
//
// Lifecycle:
//
//   1. `init(configuration:)` opens the underlying `ClickHouseClient`
//      eagerly so the `client` accessor is valid the moment the
//      service has been constructed. A handshake failure throws the
//      typed `ClickHouseError` immediately; the service is not created.
//
//   2. `run()` is the ServiceLifecycle entry point. It parks the
//      service task until graceful shutdown is signalled by the
//      surrounding `ServiceGroup`. On signal, in-flight queries are
//      allowed up to `configuration.shutdownGracePeriod` to drain
//      before the underlying connection is closed.
//
//   3. The drain follows ServiceLifecycle's documented contract: the
//      grace period is bounded; if work has not finished by then the
//      socket is closed regardless and any blocked operations surface
//      a typed I/O error to their respective tasks.
//
// Usage:
//
//   let service = try await ClickHouseService(
//       configuration: .init(endpoints: [.init(host: "localhost", port: 9000)])
//   )
//   let group = ServiceGroup(services: [service, otherService])
//   try await group.run()
//   // From application code:
//   let rows: [Row] = try await service.client.select("...", as: Row.self).collect()
public actor ClickHouseService: Service {

    public nonisolated let client: ClickHouseClient
    private let configuration: ClickHouseConfiguration

    public init(configuration: ClickHouseConfiguration) async throws(ClickHouseError) {
        self.configuration = configuration
        self.client = try await ClickHouseClient(configuration: configuration)
    }

    // ServiceLifecycle entry point. Parks until the surrounding
    // ServiceGroup signals graceful shutdown, then drains in-flight
    // queries within `configuration.shutdownGracePeriod` before closing
    // the underlying client.
    public func run() async throws {
        let logger = configuration.logger
        logger.notice("ClickHouseService started", metadata: ["endpoints": .string(endpointsDescription)])
        try await gracefulShutdown()
        logger.notice("ClickHouseService draining", metadata: ["grace": .string("\(configuration.shutdownGracePeriod)")])
        await drainThenClose()
        logger.notice("ClickHouseService stopped")
    }

    private nonisolated var endpointsDescription: String {
        configuration.endpoints.map { $0.description }.joined(separator: ",")
    }

    // Drains in-flight queries up to the configured grace period, then
    // closes the underlying client. The drain is implemented as a race
    // between the client's natural `close()` (which serialises through
    // the worker queue and therefore only fires after queued work
    // completes) and a deadline timer. When the deadline wins, `close()`
    // still runs; queued work surfaces a typed I/O error to its caller
    // once the socket is gone.
    func drainThenClose() async {
        let grace = configuration.shutdownGracePeriod
        let logger = configuration.logger
        let client = self.client
        await withTaskGroup(of: DrainOutcome.self) { group in
            group.addTask {
                await client.close()
                return .drained
            }
            group.addTask {
                try? await Task.sleep(for: grace)
                return .gracePeriodElapsed
            }
            switch await group.next() {
            case .drained:
                group.cancelAll()
            case .gracePeriodElapsed:
                logger.warning("ClickHouseService grace period elapsed; closing connection regardless")
                group.cancelAll()
                // forceClose, not close: a graceful close enqueues behind
                // the serial worker and would never run while a query is
                // stuck in recv, so the grace period would not bound
                // shutdown at all.
                await client.forceClose()
            case .none:
                break
            }
        }
    }

    private enum DrainOutcome: Sendable {
        case drained
        case gracePeriodElapsed
    }
}
