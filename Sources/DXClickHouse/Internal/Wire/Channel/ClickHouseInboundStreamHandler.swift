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

// Bridges NIO's callback-driven channelRead into Swift structured
// concurrency by yielding each decoded ClickHouseServerPacket onto an
// AsyncThrowingStream. Consumers iterate the stream via
// `for try await packet in handler.packets`.
//
// The stream finishes cleanly on `channelInactive` and finishes with
// the propagated error on `errorCaught`, so consumers see a single
// well-defined termination signal rather than special-cased "channel
// closed" errors.
final class ClickHouseInboundStreamHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = ClickHouseServerPacket

    let packets: AsyncThrowingStream<ClickHouseServerPacket, Error>
    private let continuation: AsyncThrowingStream<ClickHouseServerPacket, Error>.Continuation

    init() {
        let (stream, continuation) = AsyncThrowingStream<ClickHouseServerPacket, Error>.makeStream()
        self.packets = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        continuation.yield(packet)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

}
