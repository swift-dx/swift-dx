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

// Reads the single cleartext byte PostgreSQL sends in reply to an SSLRequest:
// 'S' to accept TLS or 'N' to decline. The byte arrives before any TLS records,
// so this one-shot handler captures exactly one byte, fulfils the promise, and
// removes itself from the pipeline; the connection code then installs the TLS
// handler (on 'S') or fails the connect (on 'N' when TLS is required).
//
// `@unchecked Sendable` is sound because the handler is pinned to its channel's
// event loop: `fulfilled` is only read and written on that loop, and the promise
// it completes is itself Sendable.
final class SSLNegotiationResponseHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {

    typealias InboundIn = ByteBuffer

    private let responseByte: EventLoopPromise<UInt8>
    private var fulfilled = false

    init(responseByte: EventLoopPromise<UInt8>) {
        self.responseByte = responseByte
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        guard let byte = buffer.readInteger(as: UInt8.self), !fulfilled else { return }
        fulfilled = true
        responseByte.succeed(byte)
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !fulfilled else { return }
        fulfilled = true
        responseByte.fail(PostgresError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !fulfilled else { return }
        fulfilled = true
        responseByte.fail(error)
        context.close(promise: nil)
    }
}
