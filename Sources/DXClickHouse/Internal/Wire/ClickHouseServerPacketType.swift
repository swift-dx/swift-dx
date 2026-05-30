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

// UVarInt type markers for packets the server sends to the client.
// The marker is read first; the per-packet body follows and is dispatched
// by the connection's read path based on the marker.
enum ClickHouseServerPacketType: UInt64, Sendable {

    case hello = 0
    case data = 1
    case exception = 2
    case progress = 3
    case pong = 4
    case endOfStream = 5
    case profileInfo = 6
    case totals = 7
    case extremes = 8
    case tablesStatusResponse = 9
    case log = 10
    case tableColumns = 11
    case partUUIDs = 12
    case readTaskRequest = 13
    case profileEvents = 14
    // Newer types added in CH 24.x/25.x. Server gates each on the
    // negotiated revision. We recognize them as known type markers so
    // the packet stream doesn't desync, then handle the body in the
    // packet reader (TimezoneUpdate is parsed and observed; the others
    // are reserved-for-now fail-soft cases).
    case mergeTreeAllRangesAnnouncement = 15
    case mergeTreeReadTaskRequest = 16
    case timezoneUpdate = 17
    case sshChallenge = 18

    static func read(from buffer: inout ByteBuffer) throws -> ClickHouseServerPacketType {
        let raw = try buffer.readClickHouseUVarInt()
        guard let type = ClickHouseServerPacketType(rawValue: raw) else {
            throw ClickHouseError.unknownServerPacketType(rawValue: raw)
        }
        return type
    }

    func write(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseUVarInt(rawValue)
    }

}
