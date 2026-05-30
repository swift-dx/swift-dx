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

// Channel-pipeline adapter: drains the inbound ByteBuffer through
// ClickHouseFraming, firing one ClickHouseServerPacket per call. NIO
// invokes `decode` in a loop while we return `.continue`, which lets
// us drain a buffer that holds multiple packets without needing our
// own loop. `.needMoreData` tells NIO to hold the buffer and call us
// again on the next socket read.
//
// The decoder is instantiated with an immutable revision; the
// handshake orchestrator installs fresh instances with the negotiated
// revision after Hello completes via a separate raw-byte path.
struct ClickHouseInboundDecoder: ByteToMessageDecoder {

    typealias InboundOut = ClickHouseServerPacket

    let revision: UInt64
    let compression: ClickHouseCompressionMethod

    init(revision: UInt64, compression: ClickHouseCompressionMethod = .uncompressed) {
        self.revision = revision
        self.compression = compression
    }

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let frame = try ClickHouseFraming.tryFrame(from: &buffer) { incoming in
            try ClickHouseServerPacketReader.read(from: &incoming, revision: revision, compression: compression)
        }
        switch frame {
        case .complete(let packet):
            context.fireChannelRead(self.wrapInboundOut(packet))
            return .continue
        case .needsMoreBytes:
            return .needMoreData
        }
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        let state = try decode(context: context, buffer: &buffer)
        // Throw "truncated" only when the decoder could NOT make
        // progress (`.needMoreData`) AND bytes remain AND we won't get
        // any more. A pre-fix version threw whenever bytes remained,
        // even if `decode` had just consumed a complete packet and was
        // about to be called again (NIO loops on `.continue`). That
        // would interrupt draining a multi-packet buffer at EOF and
        // mis-frame the trailing packets as truncation. Standard NIO
        // flow normally drains via `decode` before reaching this point,
        // so the practical effect is defense-in-depth, not a
        // user-visible behavior change.
        if seenEOF, state == .needMoreData, buffer.readableBytes > 0 {
            throw ClickHouseError.truncatedBuffer(needed: 1, available: buffer.readableBytes)
        }
        return state
    }

}
