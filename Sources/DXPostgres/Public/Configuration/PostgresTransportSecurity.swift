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

/// Whether the connection runs in cleartext or over TLS. There is no negotiated
/// "prefer TLS, fall back to plaintext" mode: that would be a silent downgrade.
/// With ``tls(_:)`` the client sends an `SSLRequest` and, if the server declines,
/// fails with ``PostgresError/tlsNotSupportedByServer`` rather than continuing in
/// cleartext.
public enum PostgresTransportSecurity: Sendable {

    case plaintext
    case tls(PostgresTLSConfiguration)
}
