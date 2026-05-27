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

/// Where the JetStream client should obtain NATS NKey credentials when
/// negotiating the handshake.
///
/// NATS authentication uses NKeys: an Ed25519 keypair where the public
/// key (an NKey) identifies the account or user, and the private seed
/// signs a per-connection nonce issued by the server. The canonical
/// container is a `.creds` file produced by the `nsc` CLI; it bundles a
/// signed JWT alongside the seed.
///
/// The cases of `NatsCredentialsSource` cover the common ways enterprise
/// deployments supply that creds payload to a running process:
/// directly in-memory, inline base64 in configuration, or via an
/// environment variable populated by a secret manager.
public enum NatsCredentialsSource: Sendable {

    /// Connect without authentication. Suitable for local development
    /// brokers configured with `--no_auth` or open subjects. Production
    /// brokers reject anonymous handshakes.
    case anonymous

    /// Use a ``NatsCredentials`` value already constructed in memory.
    /// Useful for tests and for code that pulls credentials from a
    /// secret-management SDK and hands them in directly.
    case literal(NatsCredentials)

    /// A base64-encoded `.creds` file payload supplied inline as a
    /// `String`. Use when the secret is read from a configuration
    /// source that hands you the encoded bytes directly (Kubernetes
    /// secret mounted as a string field, Vault response, etc.).
    case base64String(String)

    /// The name of an environment variable holding the base64-encoded
    /// `.creds` file payload. The variable is resolved and decoded
    /// during `connect`, never at configuration time, so a missing or
    /// malformed value surfaces as a connection error with the variable
    /// name attached for operational diagnosis.
    case base64Environment(variable: String)
}
