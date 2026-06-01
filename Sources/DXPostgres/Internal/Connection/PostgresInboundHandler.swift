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

// Accumulates socket bytes and decodes every complete backend message available
// in one read, handing the batch to the message stream under a single lock. A
// partial trailing frame is retained in the accumulator and completed by a later
// read. A decode failure (malformed framing) or channel close fails the stream
// so the parked request resumes with a typed error instead of hanging.
//
// `@unchecked Sendable` is sound because the handler is pinned to its channel's
// event loop, so `accumulator` is only ever touched on that loop, and the stream
// it writes to is itself lock-guarded.
final class PostgresInboundHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = ByteBuffer

    private let stream: PostgresMessageStream
    private var accumulator: ByteBuffer

    init(stream: PostgresMessageStream, allocator: ByteBufferAllocator) {
        self.stream = stream
        self.accumulator = allocator.buffer(capacity: 16 * 1024)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = Self.unwrapInboundIn(data)
        absorb(&incoming)
        drain(context: context)
    }

    private func absorb(_ incoming: inout ByteBuffer) {
        guard accumulator.readableBytes > 0 else {
            accumulator = incoming
            return
        }
        accumulator.writeBuffer(&incoming)
    }

    private func drain(context: ChannelHandlerContext) {
        do {
            let messages = try decodeAll()
            accumulator.discardReadBytes()
            stream.deliver(messages)
        } catch {
            stream.fail(error)
            context.close(promise: nil)
        }
    }

    private func decodeAll() throws(PostgresError) -> [BackendMessage] {
        var messages: [BackendMessage] = []
        while try decodeNext(into: &messages) {}
        return messages
    }

    private func decodeNext(into messages: inout [BackendMessage]) throws(PostgresError) -> Bool {
        switch try BackendMessageDecoder.decodeOne(from: accumulator) {
        case .needMore:
            return false
        case .message(let message, let consumed):
            accumulator.moveReaderIndex(forwardBy: consumed)
            messages.append(message)
            return true
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        stream.fail(.transportError(reason: String(describing: error)))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        stream.fail(.connectionClosed)
        context.fireChannelInactive()
    }
}
