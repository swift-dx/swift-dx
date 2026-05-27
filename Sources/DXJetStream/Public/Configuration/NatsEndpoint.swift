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

/// A NATS broker address: a host and a TCP port the client dials during
/// connection.
///
/// `NatsEndpoint` describes one server. NATS clusters are discovered
/// server-side after the first connection succeeds — the broker advertises
/// its peers via the NATS `INFO` frame, so the value passed here can be
/// any reachable cluster member.
///
/// For local development the host is typically `localhost`. For Kubernetes
/// deployments it is the in-cluster service DNS name (for example
/// `nats.default.svc.cluster.local`). For self-hosted single-node brokers
/// it is the broker's IP address or hostname.
public struct NatsEndpoint: Sendable, Hashable {

    /// The DNS name or IP address the client dials.
    public let host: String

    /// The TCP port the client dials. Defaults to `4222`, the standard
    /// NATS client port. Override only when the broker is configured to
    /// listen on a non-default port.
    public let port: Int

    /// Create an endpoint.
    ///
    /// - Parameters:
    ///   - host: The DNS name or IP address of the NATS broker.
    ///   - port: The TCP port the broker accepts client connections
    ///     on. Defaults to `4222`, the NATS protocol's standard client
    ///     port.
    public init(host: String, port: Int = 4222) {
        self.host = host
        self.port = port
    }
}
