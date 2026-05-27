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

import NIOCore
import NIOPosix

/// Inputs required to open a JetStream client session against a NATS broker.
///
/// Bundles every value the client needs to negotiate a connection: the
/// broker address, an authentication source, the logger that observes
/// lifecycle events, and the event-loop group that runs the underlying
/// network I/O.
///
/// Two initializers cover the two common deployment shapes:
///
/// - The ``init(endpoint:credentials:logger:expectedConnections:)`` form
///   creates a private thread pool sized to your expected connection
///   count. Use it when this client owns its own I/O resources.
/// - The ``init(endpoint:credentials:logger:eventLoopGroup:)`` form accepts
///   an externally-owned group. Use it to share a thread pool with other
///   swift-server libraries running in the same process (HTTP server,
///   PostgreSQL client, etc.) so CPU resources are not fragmented across
///   per-library pools.
public struct JetStreamConfiguration: Sendable {

    /// The NATS broker the client connects to. A single host/port pair;
    /// cluster topology is discovered server-side via the NATS `INFO`
    /// frame after connection.
    public var endpoint: NatsEndpoint

    /// How the client authenticates during the NATS handshake.
    ///
    /// NATS uses the NKey credentials scheme: a JWT that identifies the
    /// user and an Ed25519 seed that signs a server-issued nonce. The
    /// canonical container is a `.creds` file produced by the `nsc` CLI.
    ///
    /// Pick the case of ``NatsCredentialsSource`` that matches how your
    /// deployment supplies that file:
    /// - ``NatsCredentialsSource/anonymous`` — no auth. Use against an
    ///   unauthenticated broker (`--no_auth`) for local development.
    /// - ``NatsCredentialsSource/literal(_:)`` — inline ``NatsCredentials``
    ///   you constructed in code. Suitable for tests.
    /// - ``NatsCredentialsSource/base64String(_:)`` — the `.creds` file
    ///   contents, base64-encoded, supplied as a string.
    /// - ``NatsCredentialsSource/base64Environment(variable:)`` — the
    ///   name of an environment variable holding the base64-encoded
    ///   `.creds` payload. Resolution happens during `connect`, so a
    ///   missing or unparsable variable surfaces as a connection error
    ///   that names the variable.
    public var credentials: NatsCredentialsSource

    /// Receives operational events emitted by the client during its
    /// lifecycle: handshake stages, connect and disconnect transitions,
    /// publish and fetch progress, and errors.
    ///
    /// Defaults to ``NatsLogger/silent``, which drops every event. Use
    /// ``NatsLogger/standard(label:)`` to forward to swift-log's default
    /// `Logger`, or `NatsLogger(myLogger)` to plug in an existing
    /// configured `Logger`. The client emits no events outside this
    /// logger; there is no global side channel.
    public var logger: NatsLogger

    /// The event-loop group that runs network I/O for this client.
    ///
    /// Set internally by the convenience initializer; assigned directly
    /// by the externally-owned initializer. The client makes no
    /// assumption about ownership: if your code created the group, your
    /// code must shut it down. If the convenience initializer created
    /// it, the group lives as long as this configuration value.
    public var eventLoopGroup: any EventLoopGroup

    /// Create a configuration with a private, automatically-sized
    /// thread pool.
    ///
    /// - Parameters:
    ///   - endpoint: The NATS broker the client connects to. See
    ///     ``NatsEndpoint`` for host and port conventions.
    ///   - credentials: The authentication source. Defaults to
    ///     ``NatsCredentialsSource/anonymous``, which connects without
    ///     authentication and only works against an unauthenticated
    ///     broker. Production deployments override this with a creds
    ///     source. See the ``credentials`` property documentation for
    ///     the available shapes.
    ///   - logger: Sink for operational events. Defaults to
    ///     ``NatsLogger/silent`` so the client emits no log output by
    ///     default. Override to forward connection, publish, and fetch
    ///     events into your application's logging pipeline.
    ///   - expectedConnections: Hint used to size the private thread
    ///     pool: one I/O thread per expected connection, capped at the
    ///     host CPU count and at minimum 1. Most applications open a
    ///     single JetStream client per process and leave this at the
    ///     default of 1. Raise it only if this process opens multiple
    ///     concurrent JetStream clients (for example, sharding subjects
    ///     across separate brokers).
    public init(endpoint: NatsEndpoint, credentials: NatsCredentialsSource = .anonymous, logger: NatsLogger = .silent, expectedConnections: Int = 1) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.logger = logger
        let cpus = max(1, System.coreCount)
        let threads = max(1, min(expectedConnections, cpus))
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: threads)
    }

    /// Create a configuration backed by an externally-managed
    /// event-loop group.
    ///
    /// - Parameters:
    ///   - endpoint: The NATS broker the client connects to. See
    ///     ``NatsEndpoint`` for host and port conventions.
    ///   - credentials: The authentication source. Defaults to
    ///     ``NatsCredentialsSource/anonymous``. See the ``credentials``
    ///     property documentation for the available shapes.
    ///   - logger: Sink for operational events. Defaults to
    ///     ``NatsLogger/silent``.
    ///   - eventLoopGroup: A pre-existing NIO `EventLoopGroup` the
    ///     client should use for network I/O. The canonical shared
    ///     value for a swift-server application is
    ///     `MultiThreadedEventLoopGroup.singleton`. Ownership remains
    ///     with the caller; the client does not shut the group down.
    public init(endpoint: NatsEndpoint, credentials: NatsCredentialsSource = .anonymous, logger: NatsLogger = .silent, eventLoopGroup: any EventLoopGroup) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
    }
}
