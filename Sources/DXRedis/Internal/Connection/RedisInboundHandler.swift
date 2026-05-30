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

import DXCore
import NIOCore

// Accumulates socket bytes, parses every complete RESP frame available in one
// pass, and hands the whole batch to the pending queue under a single lock.
//
// Bulk and string payloads are zero-copy ByteBuffer slices that share the
// accumulator's storage, so the storage must not be mutated while a delivered
// slice still references it. Once a read produces values the accumulator is
// rebuilt into a fresh buffer holding only the (small) trailing partial frame;
// the slices retain the old storage and free it when the consumer is done. When
// a read produces no complete frame the accumulator is untouched (no slice
// references it) and the next read appends in place.
final class RedisInboundHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = ByteBuffer

    private let pending: RedisPendingQueue
    private let depthLimit: Int
    private let maxBulkBytes: Int
    private let allocator: ByteBufferAllocator
    private var accumulator: ByteBuffer
    private var arrayInProgress = false
    private var arrayRemaining = 0
    private var arrayElements: [RedisReplyArray.Element] = []
    private var arrayCursor = 0
    private var arrayFrameStart = 0

    init(pending: RedisPendingQueue, depthLimit: Int, maxBulkBytes: Int, allocator: ByteBufferAllocator) {
        self.pending = pending
        self.depthLimit = depthLimit
        self.maxBulkBytes = maxBulkBytes
        self.allocator = allocator
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
            switch pending.headShape() {
            case .values: try drainValues()
            case .arrays: try drainArrays()
            }
        } catch {
            pending.failAll(.protocolError(reason: String(describing: error)))
            context.close(promise: nil)
        }
    }

    private func drainValues() throws {
        let result = try Self.parseFrames(in: accumulator, depthLimit: depthLimit, maxBulkBytes: maxBulkBytes)
        guard !result.values.isEmpty else { return }
        rebuildAccumulator(consumed: result.consumed)
        pending.deliverBatch(result.values)
    }

    // Resumable, single-pass decode of array-shaped replies (MGET, range/geo
    // scans). The in-progress array's already-parsed elements are never
    // re-scanned across reads: the cursor and element offsets persist between
    // channelReads. While an array is mid-parse and nothing has been delivered
    // ahead of it, the accumulator is left untouched (no rebuild, no recopy of
    // the partial frame), so a large reply arriving over many reads costs one
    // parse pass and no buffer churn.
    private func drainArrays() throws {
        var values: [RESPValue] = []
        let endOffset = try collectArrayFrames(into: &values)
        let consumed = endOffset - accumulator.readerIndex
        guard consumed > 0 else {
            reserveForInProgressArray()
            return
        }
        rebuildAfterArrays(consumed: consumed, frameStart: endOffset)
        guard !values.isEmpty else { return }
        pending.deliverBatch(values)
    }

    // A large array reply (a deep MGET or range scan) arrives over several reads.
    // The element count is known from the header, so the accumulator is grown to
    // the expected frame size once instead of doubling on each read. No delivered
    // slice references the accumulator while an array is mid-parse with nothing
    // ahead of it, so this in-place growth is safe and the byte indices the
    // cursor and recorded offsets use are preserved.
    private func reserveForInProgressArray() {
        guard arrayInProgress, arrayRemaining > 0 else { return }
        accumulator.reserveCapacity(accumulator.writerIndex + arrayRemaining * 32)
    }

    // After delivering completed frames, drop their bytes. When an array is
    // still in progress its bytes are the leftover the rebuild keeps, so its
    // cursor and frame start are re-based onto the fresh buffer (whose reader
    // index is zero); recorded element offsets are relative to the frame start
    // and stay valid. When no frames preceded the in-progress array, `consumed`
    // is zero and the caller skips the rebuild entirely, so the partial frame is
    // never recopied across reads.
    private func rebuildAfterArrays(consumed: Int, frameStart: Int) {
        rebuildAccumulator(consumed: consumed)
        guard arrayInProgress else { return }
        arrayCursor -= frameStart
        arrayFrameStart = 0
    }

    private func collectArrayFrames(into values: inout [RESPValue]) throws -> Int {
        let parser = RESPParser(buffer: accumulator, depthLimit: depthLimit, maxBulkBytes: maxBulkBytes)
        let view = accumulator.readableBytesView
        var offset = accumulator.readerIndex
        while try stepArrayFrame(parser, view, offset: &offset, into: &values) {}
        return arrayInProgress ? arrayFrameStart : offset
    }

    private func stepArrayFrame(_ parser: RESPParser, _ view: ByteBufferView, offset: inout Int, into values: inout [RESPValue]) throws -> Bool {
        if arrayInProgress { return try resumeArrayFrame(parser, offset: &offset, into: &values) }
        guard offset < accumulator.writerIndex else { return false }
        return try startFrame(parser, view, offset: &offset, into: &values)
    }

    private func startFrame(_ parser: RESPParser, _ view: ByteBufferView, offset: inout Int, into values: inout [RESPValue]) throws -> Bool {
        guard view[offset] == Ascii.asterisk else { return try stepScalarFrame(parser, offset: &offset, into: &values) }
        return try startArrayFrame(parser, offset: &offset, into: &values)
    }

    private func resumeArrayFrame(_ parser: RESPParser, offset: inout Int, into values: inout [RESPValue]) throws -> Bool {
        let complete = try parser.resumeReplyArrayElements(remaining: &arrayRemaining, elements: &arrayElements, cursor: &arrayCursor, base: arrayFrameStart)
        guard complete else { return false }
        let storage = try parser.sliceFrame(from: arrayFrameStart, to: arrayCursor)
        values.append(.arrayReply(RedisReplyArray(storage: storage, elements: arrayElements)))
        offset = arrayCursor
        arrayInProgress = false
        arrayElements = []
        return true
    }

    private func startArrayFrame(_ parser: RESPParser, offset: inout Int, into values: inout [RESPValue]) throws -> Bool {
        switch try parser.beginReplyArray(from: offset) {
        case .needMore: return false
        case .nullArray(let consumedUpTo): values.append(.null); offset = consumedUpTo; return true
        case .header(let count, let elementsStart):
            arrayInProgress = true
            arrayRemaining = count
            arrayElements = []
            arrayElements.reserveCapacity(min(count, 65536))
            arrayCursor = elementsStart
            arrayFrameStart = offset
            return true
        }
    }

    private func stepScalarFrame(_ parser: RESPParser, offset: inout Int, into values: inout [RESPValue]) throws -> Bool {
        guard case .complete(let value, let bytesConsumed) = try parser.parse(from: offset) else { return false }
        values.append(value)
        offset += bytesConsumed
        return true
    }

    private func rebuildAccumulator(consumed: Int) {
        let leftoverLength = accumulator.readableBytes - consumed
        var fresh = allocator.buffer(capacity: max(leftoverLength, 4096))
        if leftoverLength > 0 {
            fresh.writeBytes(accumulator.readableBytesView.suffix(leftoverLength))
        }
        accumulator = fresh
    }

    static func parseFrames(in buffer: ByteBuffer, depthLimit: Int, maxBulkBytes: Int) throws -> (consumed: Int, values: [RESPValue]) {
        var values: [RESPValue] = []
        var offset = buffer.readerIndex
        let parser = RESPParser(buffer: buffer, depthLimit: depthLimit, maxBulkBytes: maxBulkBytes)
        while offset < buffer.writerIndex {
            guard case .complete(let value, let bytesConsumed) = try parser.parse(from: offset) else { break }
            values.append(value)
            offset += bytesConsumed
        }
        return (offset - buffer.readerIndex, values)
    }

    private enum FrameStep {

        case frame(RESPValue, consumed: Int)
        case needMore
    }

    static func parseArrayFrames(in buffer: ByteBuffer, depthLimit: Int, maxBulkBytes: Int) throws -> (consumed: Int, values: [RESPValue]) {
        var values: [RESPValue] = []
        var offset = buffer.readerIndex
        let view = buffer.readableBytesView
        let parser = RESPParser(buffer: buffer, depthLimit: depthLimit, maxBulkBytes: maxBulkBytes)
        while offset < buffer.writerIndex {
            guard case .frame(let value, let bytesConsumed) = try decodeArrayOrValue(parser, view, at: offset) else { break }
            values.append(value)
            offset += bytesConsumed
        }
        return (offset - buffer.readerIndex, values)
    }

    private static func decodeArrayOrValue(_ parser: RESPParser, _ view: ByteBufferView, at offset: Int) throws -> FrameStep {
        guard view[offset] == Ascii.asterisk else { return try decodeValueFrame(parser, at: offset) }
        guard case .complete(let array, let bytesConsumed) = try parser.parseReplyArray(from: offset) else { return .needMore }
        return .frame(.arrayReply(array), consumed: bytesConsumed)
    }

    private static func decodeValueFrame(_ parser: RESPParser, at offset: Int) throws -> FrameStep {
        guard case .complete(let value, let bytesConsumed) = try parser.parse(from: offset) else { return .needMore }
        return .frame(value, consumed: bytesConsumed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pending.failAll(.transportError(reason: String(describing: error)))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        pending.failAll(.connectionClosed)
        context.fireChannelInactive()
    }
}
