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

// Per-block metadata. Wire layout is a tiny TLV scheme keyed by field
// number — chosen so older clients can ignore fields a newer server
// adds without breaking parsing. We reject unknown fields here rather
// than skipping silently so server-side changes that affect us surface
// during development instead of silently misframing subsequent reads.
//
//   UVarInt fieldNum  (1 = isOverflows follows, 2 = bucketNumber follows,
//                      0 = end-of-info terminator)
//   loop until fieldNum == 0:
//     if fieldNum == 1: Bool isOverflows
//     if fieldNum == 2: Int32 bucketNumber
//
// Default values mirror clickhouse-go: isOverflows=false, bucketNumber=-1.
struct ClickHouseBlockInfo: Sendable, Equatable {

    var isOverflows: Bool = false
    var bucketNumber: Int32 = -1

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseUVarInt(1)
        buffer.writeClickHouseBool(isOverflows)
        buffer.writeClickHouseUVarInt(2)
        buffer.writeClickHouseFixedWidthInteger(bucketNumber)
        buffer.writeClickHouseUVarInt(0)
    }

    static func decode(from buffer: inout ByteBuffer) throws -> Self {
        var blockInfo = ClickHouseBlockInfo()
        while true {
            let fieldNumber = try buffer.readClickHouseUVarInt()
            switch fieldNumber {
            case 0:
                return blockInfo
            case 1:
                blockInfo.isOverflows = try buffer.readClickHouseBool()
            case 2:
                blockInfo.bucketNumber = try buffer.readClickHouseFixedWidthInteger(Int32.self)
            default:
                throw ClickHouseError.unknownBlockInfoField(fieldNumber)
            }
        }
    }

}
