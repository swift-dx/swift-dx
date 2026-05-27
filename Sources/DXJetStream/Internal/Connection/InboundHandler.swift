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

// Safe across threads because every mutation runs on the owning Channel's
// EventLoop. NIO's ChannelInboundHandler contract guarantees serial dispatch
// of channelRead / channelInactive / errorCaught on the same loop.
final class InboundHandler: ChannelInboundHandler, @unchecked Sendable {

    typealias InboundIn = ByteBuffer

    private let connection: JetStreamClientImpl
    private let cachedInboxPrefixBytes: [UInt8]
    private var accumulator: ByteBuffer
    private var fieldStarts: [Int]
    private var fieldEnds: [Int]

    init(connection: JetStreamClientImpl) {
        self.connection = connection
        self.accumulator = ByteBufferAllocator().buffer(capacity: 16 * 1024)
        self.cachedInboxPrefixBytes = Array(connection.inboxPrefix.utf8)
        self.fieldStarts = Array(repeating: 0, count: 6)
        self.fieldEnds = Array(repeating: 0, count: 6)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = Self.unwrapInboundIn(data)
        accumulator.writeBuffer(&buf)
        parse(context: context)
    }

    private func parse(context: ChannelHandlerContext) {
        while true {
            switch peekLineLength() {
            case .needMore:
                return
            case .found(let lineLen):
                if !dispatchOneLine(lineLen: lineLen, context: context) { return }
            }
        }
    }

    private func dispatchOneLine(lineLen: Int, context: ChannelHandlerContext) -> Bool {
        let view = accumulator.readableBytesView
        let opStart = view.startIndex
        switch identifyVerb(view: view, opStart: opStart, lineLen: lineLen) {
        case .message: return handleMessage(lineLen: lineLen, hasHeaders: false, context: context)
        case .messageWithHeaders: return handleMessage(lineLen: lineLen, hasHeaders: true, context: context)
        case .ping: return handlePing(lineLen: lineLen, context: context)
        case .pong: return handlePong(lineLen: lineLen)
        case .serverInfo: return handleServerInfo(lineLen: lineLen, opStart: opStart, view: view, context: context)
        case .protocolError: return handleProtocolError(lineLen: lineLen, opStart: opStart, view: view)
        case .unknown: return skipUnknown(lineLen: lineLen)
        }
    }

    private enum InboundVerb {
        case message
        case messageWithHeaders
        case ping
        case pong
        case serverInfo
        case protocolError
        case unknown
    }

    private func identifyVerb(view: ByteBufferView, opStart: Int, lineLen: Int) -> InboundVerb {
        guard lineLen >= 2 else { return .unknown }
        switch view[opStart] {
        case Ascii.upperM: return classifyMVerb(view: view, opStart: opStart, lineLen: lineLen)
        case Ascii.upperH: return classifyHVerb(view: view, opStart: opStart, lineLen: lineLen)
        case Ascii.upperP: return classifyPVerb(view: view, opStart: opStart, lineLen: lineLen)
        case Ascii.upperI: return classifyIVerb(view: view, opStart: opStart, lineLen: lineLen)
        case Ascii.hyphen: return classifyHyphenVerb(view: view, opStart: opStart, lineLen: lineLen)
        default: return .unknown
        }
    }

    @inline(__always)
    private func classifyMVerb(view: ByteBufferView, opStart: Int, lineLen: Int) -> InboundVerb {
        matchesPrefix(view: view, opStart: opStart, lineLen: lineLen, prefix: NatsProtocolBytes.msgOp) ? .message : .unknown
    }

    @inline(__always)
    private func classifyHVerb(view: ByteBufferView, opStart: Int, lineLen: Int) -> InboundVerb {
        matchesPrefix(view: view, opStart: opStart, lineLen: lineLen, prefix: NatsProtocolBytes.hmsgOp) ? .messageWithHeaders : .unknown
    }

    @inline(__always)
    private func classifyPVerb(view: ByteBufferView, opStart: Int, lineLen: Int) -> InboundVerb {
        guard lineLen == 4 else { return .unknown }
        return classifyPingPongSecondByte(view[opStart &+ 1])
    }

    @inline(__always)
    private func classifyPingPongSecondByte(_ byte: UInt8) -> InboundVerb {
        switch byte {
        case Ascii.upperI: return .ping
        case Ascii.upperO: return .pong
        default: return .unknown
        }
    }

    @inline(__always)
    private func classifyIVerb(view: ByteBufferView, opStart: Int, lineLen: Int) -> InboundVerb {
        matchesPrefix(view: view, opStart: opStart, lineLen: lineLen, prefix: NatsProtocolBytes.infoOp) ? .serverInfo : .unknown
    }

    @inline(__always)
    private func classifyHyphenVerb(view: ByteBufferView, opStart: Int, lineLen: Int) -> InboundVerb {
        matchesPrefix(view: view, opStart: opStart, lineLen: lineLen, prefix: NatsProtocolBytes.errOp) ? .protocolError : .unknown
    }

    @inline(__always)
    private func matchesPrefix(view: ByteBufferView, opStart: Int, lineLen: Int, prefix: [UInt8]) -> Bool {
        guard lineLen >= prefix.count else { return false }
        return allBytesEqual(view: view, opStart: opStart, prefix: prefix)
    }

    @inline(__always)
    private func allBytesEqual(view: ByteBufferView, opStart: Int, prefix: [UInt8]) -> Bool {
        for offset in 0..<prefix.count where view[opStart &+ offset] != prefix[offset] {
            return false
        }
        return true
    }

    private func handlePing(lineLen: Int, context: ChannelHandlerContext) -> Bool {
        accumulator.moveReaderIndex(forwardBy: lineLen + NatsProtocolBytes.crlfLength)
        var buffer = context.channel.allocator.buffer(capacity: NatsProtocolBytes.pongResponse.count)
        buffer.writeBytes(NatsProtocolBytes.pongResponse)
        context.channel.writeAndFlush(buffer, promise: nil)
        return true
    }

    private func handlePong(lineLen: Int) -> Bool {
        accumulator.moveReaderIndex(forwardBy: lineLen + NatsProtocolBytes.crlfLength)
        connection.signalHandshakeSuccess()
        return true
    }

    private func handleServerInfo(lineLen: Int, opStart: Int, view: ByteBufferView, context: ChannelHandlerContext) -> Bool {
        let nonce = JSONScan.field(view, start: opStart + NatsProtocolBytes.infoOp.count, end: opStart + lineLen, key: NatsProtocolBytes.nonceKey)
        accumulator.moveReaderIndex(forwardBy: lineLen + NatsProtocolBytes.crlfLength)
        sendConnect(context: context, nonce: nonce)
        return true
    }

    private func skipUnknown(lineLen: Int) -> Bool {
        accumulator.moveReaderIndex(forwardBy: lineLen + NatsProtocolBytes.crlfLength)
        return true
    }

    private func handleProtocolError(lineLen: Int, opStart: Int, view: ByteBufferView) -> Bool {
        let lineCopy = Array(view[opStart..<(opStart + lineLen)])
        accumulator.moveReaderIndex(forwardBy: lineLen + NatsProtocolBytes.crlfLength)
        let message = String(decoding: lineCopy, as: UTF8.self)
        connection.signalHandshakeFailed(JetStreamError.handshakeFailed(reason: message))
        return true
    }

    private func sendConnect(context: ChannelHandlerContext, nonce: String) {
        guard connection.tryMarkConnectSent() else { return }
        do {
            let bytes = try connection.buildConnectFrame(nonce: nonce)
            var buf = context.channel.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            context.writeAndFlush(NIOAny(buf), promise: nil)
        } catch {
            connection.signalHandshakeFailed(JetStreamError.handshakeFailed(reason: "\(error)"))
        }
    }

    private enum LineLength {

        case needMore
        case found(Int)
    }

    private func peekLineLength() -> LineLength {
        let view = accumulator.readableBytesView
        var i = 0
        let end = view.count - 1
        while i < end {
            if view[view.startIndex + i] == Ascii.carriageReturn, view[view.startIndex + i + 1] == Ascii.lineFeed {
                return .found(i)
            }
            i += 1
        }
        return .needMore
    }

    private enum MessageReadiness {
        case skip
        case needMore
        case ready(totalBytes: Int, needed: Int)
    }

    private func handleMessage(lineLen: Int, hasHeaders: Bool, context: ChannelHandlerContext) -> Bool {
        let view = accumulator.readableBytesView
        let opStart = view.startIndex
        let opEnd = opStart + lineLen
        let fieldCount = populateFieldBoundaries(view: view, opStart: opStart, opEnd: opEnd)
        let readiness = classifyReadiness(hasHeaders: hasHeaders, fieldCount: fieldCount, view: view, lineLen: lineLen)
        return resolveReadiness(readiness, view: view, hasHeaders: hasHeaders, fieldCount: fieldCount, lineLen: lineLen, context: context)
    }

    private func classifyReadiness(hasHeaders: Bool, fieldCount: Int, view: ByteBufferView, lineLen: Int) -> MessageReadiness {
        let expectedMin = expectedMinFields(hasHeaders: hasHeaders)
        guard fieldCount >= expectedMin else { return .skip }
        let totalBytes = ByteScan.parseInt(view, start: fieldStarts[fieldCount - 1], end: fieldEnds[fieldCount - 1])
        let needed = lineLen + NatsProtocolBytes.crlfLength + totalBytes + NatsProtocolBytes.crlfLength
        return accumulator.readableBytes < needed ? .needMore : .ready(totalBytes: totalBytes, needed: needed)
    }

    private func resolveReadiness(_ readiness: MessageReadiness, view: ByteBufferView, hasHeaders: Bool, fieldCount: Int, lineLen: Int, context: ChannelHandlerContext) -> Bool {
        switch readiness {
        case .skip: return skipUnknown(lineLen: lineLen)
        case .needMore: return false
        case .ready(let totalBytes, let needed): return dispatchReadyMessage(view: view, hasHeaders: hasHeaders, fieldCount: fieldCount, lineLen: lineLen, totalBytes: totalBytes, needed: needed)
        }
    }

    private func dispatchReadyMessage(view: ByteBufferView, hasHeaders: Bool, fieldCount: Int, lineLen: Int, totalBytes: Int, needed: Int) -> Bool {
        if tryDispatchInboxBarrier(view: view, needed: needed) { return true }
        return dispatchPayload(
            view: view,
            lineLen: lineLen,
            hasHeaders: hasHeaders,
            fieldCount: fieldCount,
            expectedMin: expectedMinFields(hasHeaders: hasHeaders),
            totalBytes: totalBytes,
            needed: needed
        )
    }

    @inline(__always)
    private func expectedMinFields(hasHeaders: Bool) -> Int {
        hasHeaders ? 5 : 4
    }

    private func populateFieldBoundaries(view: ByteBufferView, opStart: Int, opEnd: Int) -> Int {
        var fieldCount = 0
        var fieldStart = opStart
        for index in opStart..<opEnd where view[index] == Ascii.space {
            fieldCount = recordFieldIfNonEmpty(start: fieldStart, end: index, count: fieldCount)
            fieldStart = index + 1
        }
        return recordFieldIfNonEmpty(start: fieldStart, end: opEnd, count: fieldCount)
    }

    @inline(__always)
    private func recordFieldIfNonEmpty(start: Int, end: Int, count: Int) -> Int {
        guard start < end, count < 6 else { return count }
        fieldStarts[count] = start
        fieldEnds[count] = end
        return count + 1
    }

    private func tryDispatchInboxBarrier(view: ByteBufferView, needed: Int) -> Bool {
        let subjStart = fieldStarts[1]
        let subjEnd = fieldEnds[1]
        guard case .matched(let suffix) = InboxParser.parseSuffix(view, start: subjStart, end: subjEnd, prefixBytes: cachedInboxPrefixBytes) else {
            return false
        }
        guard connection.dispatchBarrierByRange(suffix: suffix) else {
            return false
        }
        accumulator.moveReaderIndex(forwardBy: needed)
        return true
    }

    private func dispatchPayload(
        view: ByteBufferView,
        lineLen: Int,
        hasHeaders: Bool,
        fieldCount: Int,
        expectedMin: Int,
        totalBytes: Int,
        needed: Int
    ) -> Bool {
        let hasReply = fieldCount == expectedMin + 1
        let sid = UInt64(ByteScan.parseInt(view, start: fieldStarts[2], end: fieldEnds[2]))
        let status = readStatus(view: view, hasHeaders: hasHeaders, lineLen: lineLen, fieldCount: fieldCount)
        let replyBytes: [UInt8] = hasReply ? Array(view[fieldStarts[3]..<fieldEnds[3]]) : []
        let subjectBytes: [UInt8] = Array(view[fieldStarts[1]..<fieldEnds[1]])

        if sid != connection.sharedInboxSidValue, tryDispatchBySid(view: view, sid: sid, subjectBytes: subjectBytes, replyBytes: replyBytes, status: status, hasHeaders: hasHeaders, lineLen: lineLen, totalBytes: totalBytes, fieldCount: fieldCount, needed: needed) {
            return true
        }

        deliverSlowPath(
            view: view,
            sid: sid,
            replyBytes: replyBytes,
            hasReply: hasReply,
            hasHeaders: hasHeaders,
            lineLen: lineLen,
            fieldCount: fieldCount,
            totalBytes: totalBytes
        )
        return true
    }

    private func tryDispatchBySid(
        view: ByteBufferView,
        sid: UInt64,
        subjectBytes: [UInt8],
        replyBytes: [UInt8],
        status: NatsMessageStatus,
        hasHeaders: Bool,
        lineLen: Int,
        totalBytes: Int,
        fieldCount: Int,
        needed: Int
    ) -> Bool {
        let payloadResult = readPayload(view: view, hasHeaders: hasHeaders, lineLen: lineLen, totalBytes: totalBytes, fieldCount: fieldCount, status: status, needsPayload: connection.fetchNeedsPayload(sid: sid))
        let inboundHeaders = readHeaders(view: view, hasHeaders: hasHeaders, lineLen: lineLen, fieldCount: fieldCount, status: status)
        if connection.dispatchFetchStream(sid: sid, subject: subjectBytes, reply: replyBytes, headers: inboundHeaders, payload: payloadResult, status: status) {
            accumulator.moveReaderIndex(forwardBy: needed)
            return true
        }
        if connection.dispatchFetchBySid(sid: sid, subject: subjectBytes, reply: replyBytes, headers: inboundHeaders, payload: payloadResult, status: status) {
            accumulator.moveReaderIndex(forwardBy: needed)
            return true
        }
        return false
    }

    private func readHeaders(view: ByteBufferView, hasHeaders: Bool, lineLen: Int, fieldCount: Int, status: NatsMessageStatus) -> [NatsHeader] {
        guard hasHeaders, case .ok = status else { return [] }
        let hlen = ByteScan.parseInt(view, start: fieldStarts[fieldCount - 2], end: fieldEnds[fieldCount - 2])
        guard hlen > 12 else { return [] }
        let blockStart = view.startIndex + lineLen + NatsProtocolBytes.crlfLength
        return HeaderBlockParser.parse(view: view, from: blockStart, length: hlen)
    }

    private func deliverSlowPath(
        view: ByteBufferView,
        sid: UInt64,
        replyBytes: [UInt8],
        hasReply: Bool,
        hasHeaders: Bool,
        lineLen: Int,
        fieldCount: Int,
        totalBytes: Int
    ) {
        let subjStart = fieldStarts[1]
        let subjEnd = fieldEnds[1]
        accumulator.moveReaderIndex(forwardBy: lineLen + NatsProtocolBytes.crlfLength)
        let subject = String(decoding: view[subjStart..<subjEnd], as: UTF8.self)
        let replyAddress: ReplyAddress = hasReply ? .subject(String(decoding: replyBytes, as: UTF8.self)) : .none
        let drained = drainSlowPathHeadersAndPayload(hasHeaders: hasHeaders, totalBytes: totalBytes, view: view, fieldCount: fieldCount)
        connection.dispatchSlow(subject: subject, sid: sid, reply: replyAddress, headers: drained.headers, payload: drained.payload)
    }

    private func drainSlowPathHeadersAndPayload(hasHeaders: Bool, totalBytes: Int, view: ByteBufferView, fieldCount: Int) -> (headers: [NatsHeader], payload: [UInt8]) {
        guard hasHeaders else {
            let payload = drainBytes(totalBytes)
            accumulator.moveReaderIndex(forwardBy: NatsProtocolBytes.crlfLength)
            return ([], payload)
        }
        let hlen = ByteScan.parseInt(view, start: fieldStarts[fieldCount - 2], end: fieldEnds[fieldCount - 2])
        let headers: [NatsHeader] = drainHeaderBlock(hlen: hlen)
        let payloadLen = totalBytes - hlen
        let payload = drainBytes(payloadLen)
        accumulator.moveReaderIndex(forwardBy: NatsProtocolBytes.crlfLength)
        return (headers, payload)
    }

    private func drainHeaderBlock(hlen: Int) -> [NatsHeader] {
        guard hlen > 12 else {
            accumulator.moveReaderIndex(forwardBy: hlen)
            return []
        }
        let bytes = drainBytes(hlen)
        return HeaderBlockParser.parse(bytes)
    }

    private func readStatus(view: ByteBufferView, hasHeaders: Bool, lineLen: Int, fieldCount: Int) -> NatsMessageStatus {
        guard hasHeaders else { return .ok }
        let hStart = headerStartIfStatusEligible(view: view, lineLen: lineLen, fieldCount: fieldCount)
        guard hStart >= 0 else { return .ok }
        return statusFrom(code: parseStatusCode(view: view, headerStart: hStart))
    }

    @inline(__always)
    private func statusFrom(code: UInt16) -> NatsMessageStatus {
        code > 0 ? .code(code) : .ok
    }

    private func headerStartIfStatusEligible(view: ByteBufferView, lineLen: Int, fieldCount: Int) -> Int {
        let hlen = ByteScan.parseInt(view, start: fieldStarts[fieldCount - 2], end: fieldEnds[fieldCount - 2])
        guard hlen >= 12 else { return -1 }
        let hStart = view.startIndex + lineLen + NatsProtocolBytes.crlfLength
        return view[hStart + 8] == Ascii.space ? hStart : -1
    }

    private func parseStatusCode(view: ByteBufferView, headerStart: Int) -> UInt16 {
        var code: UInt16 = 0
        for index in (headerStart + 9)..<(headerStart + 12) {
            code = absorbDigit(view[index], into: code)
        }
        return code
    }

    @inline(__always)
    private func absorbDigit(_ byte: UInt8, into code: UInt16) -> UInt16 {
        guard byte >= Ascii.digitZero, byte <= Ascii.digitNine else { return code }
        return code &* 10 &+ UInt16(byte - Ascii.digitZero)
    }

    private func readPayload(view: ByteBufferView, hasHeaders: Bool, lineLen: Int, totalBytes: Int, fieldCount: Int, status: NatsMessageStatus, needsPayload: Bool) -> [UInt8] {
        guard needsPayload, case .ok = status else { return [] }
        let payloadStart: Int
        let payloadLen: Int
        if hasHeaders {
            let hlen = ByteScan.parseInt(view, start: fieldStarts[fieldCount - 2], end: fieldEnds[fieldCount - 2])
            payloadStart = view.startIndex + lineLen + NatsProtocolBytes.crlfLength + hlen
            payloadLen = totalBytes - hlen
        } else {
            payloadStart = view.startIndex + lineLen + NatsProtocolBytes.crlfLength
            payloadLen = totalBytes
        }
        return Array(view[payloadStart..<(payloadStart + payloadLen)])
    }

    private func drainBytes(_ count: Int) -> [UInt8] {
        var collected: [UInt8] = []
        collected.reserveCapacity(count)
        if let bytes = accumulator.readBytes(length: count) {
            collected.append(contentsOf: bytes)
        }
        return collected
    }
}
