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

// Temporary inbound handler installed during the handshake phase.
// Buffers raw socket bytes into an AsyncThrowingStream so the connect
// factory can drive ClickHouseHandshake.process(incoming:) with each
// chunk that arrives. Removed from the pipeline once the handshake
// completes; the typed encoder/decoder + inbound stream handler take
// over from there.
final class ClickHouseHandshakeReceiver: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {

    typealias InboundIn = ByteBuffer

    let chunks: AsyncThrowingStream<ByteBuffer, Error>
    private let continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation

    init() {
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        self.chunks = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

}
