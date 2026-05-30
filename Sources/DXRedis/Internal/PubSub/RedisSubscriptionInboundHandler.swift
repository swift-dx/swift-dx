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

// Inbound handler for a connection held in subscribe mode. Unlike the request/
// reply handler, replies here are unsolicited push frames the server sends as
// publishers publish, so there is no FIFO correlation: every complete RESP frame
// is parsed and handed to `onFrame`, and a closed channel is reported through
// `onClose` so the subscription manager can reconnect. Frame parsing reuses the
// shared RESP parser; only the routing differs.
final class RedisSubscriptionInboundHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = ByteBuffer

    private let depthLimit: Int
    private let maxBulkBytes: Int
    private let allocator: ByteBufferAllocator
    private var accumulator: ByteBuffer
    private let onFrame: @Sendable (RESPValue) -> Void
    private let onClose: @Sendable () -> Void

    init(depthLimit: Int, maxBulkBytes: Int, allocator: ByteBufferAllocator, onFrame: @escaping @Sendable (RESPValue) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.depthLimit = depthLimit
        self.maxBulkBytes = maxBulkBytes
        self.allocator = allocator
        self.accumulator = allocator.buffer(capacity: 16 * 1024)
        self.onFrame = onFrame
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = Self.unwrapInboundIn(data)
        absorb(&incoming)
        deliver(context: context)
    }

    private func absorb(_ incoming: inout ByteBuffer) {
        guard accumulator.readableBytes > 0 else {
            accumulator = incoming
            return
        }
        accumulator.writeBuffer(&incoming)
    }

    private func deliver(context: ChannelHandlerContext) {
        do {
            try drainFrames()
        } catch {
            context.close(promise: nil)
        }
    }

    private func drainFrames() throws {
        let result = try RedisInboundHandler.parseFrames(in: accumulator, depthLimit: depthLimit, maxBulkBytes: maxBulkBytes)
        guard !result.values.isEmpty else { return }
        rebuildAccumulator(consumed: result.consumed)
        forward(result.values)
    }

    private func forward(_ values: [RESPValue]) {
        for value in values {
            onFrame(value)
        }
    }

    private func rebuildAccumulator(consumed: Int) {
        let leftoverLength = accumulator.readableBytes - consumed
        var fresh = allocator.buffer(capacity: max(leftoverLength, 4096))
        if leftoverLength > 0 {
            fresh.writeBytes(accumulator.readableBytesView.suffix(leftoverLength))
        }
        accumulator = fresh
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose()
        context.close(promise: nil)
    }
}
