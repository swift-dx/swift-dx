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

// Snapshot of everything established during the handshake. Every
// subsequent operation (Query, Data, Cancel, etc.) needs the
// negotiated revision to gate its conditional fields, so threading
// this value through call chains keeps that requirement explicit.
//
// Helpers (`serverDisplayName`, `serverTimezone`) centralize the
// "use server name when display name is absent" and "default UTC when
// timezone is absent" defaults so callers don't reinvent them.
struct ClickHouseConnectionMetadata: Sendable, Equatable {

    let negotiatedRevision: UInt64
    let clientHello: ClickHouseClientHelloPacket
    let serverHello: ClickHouseServerHelloPacket

    var serverDisplayName: String {
        switch serverHello.displayName {
        case .value(let name) where !name.isEmpty: name
        default: serverHello.serverName
        }
    }

    var serverTimezone: String {
        serverHello.serverTimezone.unwrapOrDefault("UTC")
    }

    var serverVersionString: String {
        switch serverHello.versionPatch {
        case .value(let patch):
            return "\(serverHello.versionMajor).\(serverHello.versionMinor).\(patch)"
        case .unsupported:
            return "\(serverHello.versionMajor).\(serverHello.versionMinor)"
        }
    }

    var publicServerInfo: ClickHouseServerInfo {
        .init(
            name: serverHello.serverName,
            version: serverVersionString,
            timezone: serverTimezone,
            displayName: serverDisplayName,
            revision: negotiatedRevision
        )
    }

}
