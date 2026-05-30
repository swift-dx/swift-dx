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

// Channel-pipeline adapter: serializes a typed ClickHouseClientPacket
// to wire bytes via ClickHouseClientPacketWriter. Stateless; revision
// is captured at construction by the handshake orchestrator after the
// negotiated revision is known.
struct ClickHouseOutboundEncoder: MessageToByteEncoder {

    typealias OutboundIn = ClickHouseClientPacket

    let revision: UInt64
    let compression: ClickHouseCompressionMethod

    init(revision: UInt64, compression: ClickHouseCompressionMethod = .uncompressed) {
        self.revision = revision
        self.compression = compression
    }

    func encode(data: ClickHouseClientPacket, out: inout ByteBuffer) throws {
        try ClickHouseClientPacketWriter.write(data, into: &out, revision: revision, compression: compression)
    }

}
