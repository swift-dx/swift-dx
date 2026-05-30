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

// Sent immediately after the server hello, gated on
// DBMS_MIN_PROTOCOL_VERSION_WITH_ADDENDUM (54_458). No packet-type
// marker — just the field stream below, written directly to the wire.
//
// Wire layout (each field gated on the negotiated revision):
//   String   quota_key                              (>= 54_458)
//   String   proto_send_chunked_cl                  (>= 54_470)
//   String   proto_recv_chunked_cl                  (>= 54_470)
//   UVarInt  client_parallel_replicas_protocol_ver  (>= 54_471)
//
// Modern CH refuses to proceed past hello without this; the server
// reads addendum first, then waits for the Query packet.
struct ClickHouseClientAddendumPacket: Sendable, Equatable {

    static let revisionWithAddendum: UInt64 = 54_458
    static let revisionWithChunkedPackets: UInt64 = 54_470
    static let revisionWithVersionedParallelReplicas: UInt64 = 54_471

    var quotaKey: String = ""
    var protoSendChunked: String = "notchunked"
    var protoRecvChunked: String = "notchunked"
    var parallelReplicasProtocolVersion: UInt64 = 0

    func encode(into buffer: inout ByteBuffer, revision: UInt64) {
        if revision >= Self.revisionWithAddendum {
            buffer.writeClickHouseString(quotaKey)
        }
        encodeChunkedAndReplicas(into: &buffer, revision: revision)
    }

    private func encodeChunkedAndReplicas(into buffer: inout ByteBuffer, revision: UInt64) {
        if revision >= Self.revisionWithChunkedPackets {
            buffer.writeClickHouseString(protoSendChunked)
            buffer.writeClickHouseString(protoRecvChunked)
        }
        if revision >= Self.revisionWithVersionedParallelReplicas {
            buffer.writeClickHouseUVarInt(parallelReplicasProtocolVersion)
        }
    }

}
