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

/// The role and secret the client presents during the startup handshake.
/// PostgreSQL always requires a role name, so both cases carry `username`. The
/// server decides which authentication method to demand; the client supplies the
/// same password regardless of whether the server asks for SCRAM-SHA-256, MD5, or
/// cleartext. Use ``trust(username:)`` only against a server configured for
/// `trust` authentication — if such a server unexpectedly demands a password the
/// handshake fails with ``PostgresError/authenticationFailed(reason:)`` rather
/// than sending an empty secret.
public enum PostgresCredentials: Sendable, Hashable {

    case trust(username: String)
    case password(username: String, password: String)

    public var username: String {
        switch self {
        case .trust(let username): username
        case .password(let username, _): username
        }
    }
}
