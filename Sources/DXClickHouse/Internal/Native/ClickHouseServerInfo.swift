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

// Server-side metadata established during the handshake. Returned by
// `ClickHouseClient.serverInfo()` for diagnostics, logging, and
// version-conditional client behavior (e.g., gating use of newer
// type names on the server's revision).
//
// `version` is composed as "Major.Minor.Patch" from the three integer
// fields the server reports; older servers (revision < 54401) don't
// emit a patch number, in which case it's "Major.Minor".
//
// `negotiatedRevision` is `min(client_revision, server_revision)`;
// every conditional protocol field is gated on this value rather than
// either side's individual revision.
public struct ClickHouseServerInfo: Sendable, Equatable {

    public let name: String
    public let version: String
    public let timezone: String
    public let displayName: String
    public let revision: UInt64

    public init(
        name: String,
        version: String,
        timezone: String,
        displayName: String,
        revision: UInt64
    ) {
        self.name = name
        self.version = version
        self.timezone = timezone
        self.displayName = displayName
        self.revision = revision
    }

}
