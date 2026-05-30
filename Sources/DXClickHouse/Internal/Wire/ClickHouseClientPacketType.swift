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

// UVarInt type markers for packets the client sends to the server.
// The marker is written first; the per-packet body follows.
enum ClickHouseClientPacketType: UInt64, Sendable {

    case hello = 0
    case query = 1
    case data = 2
    case cancel = 3
    case ping = 4
    case tablesStatusRequest = 5

    static func read(from buffer: inout ByteBuffer) throws -> ClickHouseClientPacketType {
        let raw = try buffer.readClickHouseUVarInt()
        guard let type = ClickHouseClientPacketType(rawValue: raw) else {
            throw ClickHouseError.unknownClientPacketType(rawValue: raw)
        }
        return type
    }

    func write(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseUVarInt(rawValue)
    }

}
