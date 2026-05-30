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

// First packet the client sends after opening the TCP connection.
// Wire layout (no version conditionality at this layer):
//   String   client_name
//   UVarInt  version_major
//   UVarInt  version_minor
//   UVarInt  protocol_revision
//   String   default_database
//   String   username
//   String   password
//
// The server replies with ClickHouseServerHelloPacket and both sides
// then operate at the negotiated revision min(client, server).
struct ClickHouseClientHelloPacket: Sendable, Equatable {

    let clientName: String
    let versionMajor: UInt64
    let versionMinor: UInt64
    let protocolRevision: UInt64
    let defaultDatabase: String
    let username: String
    let password: String

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseString(clientName)
        buffer.writeClickHouseUVarInt(versionMajor)
        buffer.writeClickHouseUVarInt(versionMinor)
        buffer.writeClickHouseUVarInt(protocolRevision)
        buffer.writeClickHouseString(defaultDatabase)
        buffer.writeClickHouseString(username)
        buffer.writeClickHouseString(password)
    }

    static func decode(from buffer: inout ByteBuffer) throws -> Self {
        let clientName = try buffer.readClickHouseString()
        let versionMajor = try buffer.readClickHouseUVarInt()
        let versionMinor = try buffer.readClickHouseUVarInt()
        let protocolRevision = try buffer.readClickHouseUVarInt()
        let defaultDatabase = try buffer.readClickHouseString()
        let username = try buffer.readClickHouseString()
        let password = try buffer.readClickHouseString()
        return .init(
            clientName: clientName,
            versionMajor: versionMajor,
            versionMinor: versionMinor,
            protocolRevision: protocolRevision,
            defaultDatabase: defaultDatabase,
            username: username,
            password: password
        )
    }

}
