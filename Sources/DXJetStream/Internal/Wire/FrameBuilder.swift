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

enum FrameBuilder {

    /// Upper bound on the ASCII decimal representation of any `UInt64`.
    /// `log10(UInt64.max) ≈ 19.27`, so 20 digits cover the full range.
    static let maxDecimalDigitsUInt64 = 20

    /// Upper bound on the ASCII base36 representation of any `UInt64`.
    /// `log36(UInt64.max) ≈ 12.39`, so 13 digits cover the full range.
    static let maxBase36DigitsUInt64 = 13

    static func buildSubscribe(inbox: String, sid: UInt64) -> [UInt8] {
        Array("SUB \(inbox) \(sid)\r\n".utf8)
    }

    static func buildUnsubscribe(sid: UInt64) -> [UInt8] {
        Array("UNSUB \(sid)\r\n".utf8)
    }

    static func buildPullRequest(pubSubject: String, inbox: String, batch: Int, expiresNanos: Int64) -> [UInt8] {
        let body = "{\"batch\":\(batch),\"expires\":\(expiresNanos)}"
        let bodyBytes = Array(body.utf8)
        var frame = Array("PUB \(pubSubject) \(inbox) \(bodyBytes.count)\r\n".utf8)
        frame.append(contentsOf: bodyBytes)
        frame.append(contentsOf: NatsProtocolBytes.crlf)
        return frame
    }

    static func buildSingleRequest(subject: String, reply: String, payload: [UInt8]) -> [UInt8] {
        var frame = Array("PUB \(subject) \(reply) \(payload.count)\r\n".utf8)
        frame.append(contentsOf: payload)
        frame.append(contentsOf: NatsProtocolBytes.crlf)
        return frame
    }

    static func buildPublishBatchPlain(
        allocator: ByteBufferAllocator,
        subject: String,
        inboxPrefixBytes: [UInt8],
        payloads: [[UInt8]],
        loSuffix: UInt64
    ) -> ByteBuffer {
        let linePrefix = makeLinePrefix(op: pubOp, subject: subject, inboxPrefixBytes: inboxPrefixBytes)
        let capacity = pubBatchMaxBytes(prefixLen: linePrefix.count, payloads: payloads)

        var buf = allocator.buffer(capacity: capacity)
        buf.writeWithUnsafeMutableBytes(minimumWritableBytes: capacity) { rawPtr -> Int in
            guard let dst = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            var off = 0
            linePrefix.withUnsafeBufferPointer { prefixPtr in
                guard let prefixBase = prefixPtr.baseAddress else { return }
                let prefixLen = prefixPtr.count
                payloads.withUnsafeBufferPointer { payloadsPtr in
                    for i in 0..<payloadsPtr.count {
                        let id = loSuffix &+ UInt64(truncatingIfNeeded: i)
                        writeOnePubFrame(
                            dst: dst, off: &off,
                            prefixBase: prefixBase, prefixLen: prefixLen,
                            id: id, payload: payloadsPtr[i]
                        )
                    }
                }
            }
            return off
        }
        return buf
    }

    @inline(__always)
    private static func writeOnePubFrame(
        dst: UnsafeMutablePointer<UInt8>,
        off: inout Int,
        prefixBase: UnsafePointer<UInt8>, prefixLen: Int,
        id: UInt64,
        payload: [UInt8]
    ) {
        let payloadLen = payload.count
        let plenU64 = UInt64(truncatingIfNeeded: payloadLen)

        dst.advanced(by: off).update(from: prefixBase, count: prefixLen)
        off &+= prefixLen
        writeBase36(dst: dst, off: &off, value: id, length: base36Length(id))
        dst[off] = Ascii.space
        off &+= 1
        writeDecimal(dst: dst, off: &off, value: plenU64, length: decimalLength(plenU64))
        dst[off] = Ascii.carriageReturn
        dst[off &+ 1] = Ascii.lineFeed
        off &+= 2
        if payloadLen > 0 {
            payload.withUnsafeBufferPointer { p in
                if let base = p.baseAddress {
                    dst.advanced(by: off).update(from: base, count: payloadLen)
                }
            }
            off &+= payloadLen
        }
        dst[off] = Ascii.carriageReturn
        dst[off &+ 1] = Ascii.lineFeed
        off &+= 2
    }

    static func buildPublishBatchWithIds(
        allocator: ByteBufferAllocator,
        subject: String,
        inboxPrefixBytes: [UInt8],
        messages: [NatsOutgoingMessage],
        loSuffix: UInt64
    ) -> ByteBuffer {
        let linePrefix = makeLinePrefix(op: NatsProtocolBytes.hpubOp, subject: subject, inboxPrefixBytes: inboxPrefixBytes)
        let headerPrefix = NatsProtocolBytes.messageIdHeaderPrefix
        let headerPrefixLen = headerPrefix.count

        var capacity = 0
        for i in 0..<messages.count {
            capacity &+= hpubFrameMaxBytes(
                prefixLen: linePrefix.count,
                headerLen: headerPrefixLen,
                idBytesLen: messages[i].wireMessageId.utf8.count,
                userHeaderLen: userHeaderBytes(of: messages[i].headers),
                payloadLen: messages[i].payload.count
            )
        }

        var buf = allocator.buffer(capacity: capacity)
        buf.writeWithUnsafeMutableBytes(minimumWritableBytes: capacity) { rawPtr -> Int in
            guard let dst = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            var off = 0
            linePrefix.withUnsafeBufferPointer { prefixPtr in
            headerPrefix.withUnsafeBufferPointer { headerPtr in
                guard let prefixBase = prefixPtr.baseAddress,
                      let headerBase = headerPtr.baseAddress else { return }
                let prefixLen = prefixPtr.count
                let headerLen = headerPtr.count
                messages.withUnsafeBufferPointer { messagesPtr in
                    for i in 0..<messagesPtr.count {
                        let id = loSuffix &+ UInt64(truncatingIfNeeded: i)
                        let message = messagesPtr[i]
                        let payload = message.payload
                        let messageId = message.wireMessageId

                        let userHeaders = message.headers
                        let userHeaderLen = userHeaderBytes(of: userHeaders)
                        let idBytes = Array(messageId.utf8)
                        idBytes.withUnsafeBufferPointer { idPtr in
                            guard let idBase = idPtr.baseAddress else { return }
                            writeOneHpubFrame(
                                dst: dst, off: &off,
                                prefixBase: prefixBase, prefixLen: prefixLen,
                                headerBase: headerBase, headerLen: headerLen,
                                id: id,
                                idBase: idBase, idLen: idPtr.count,
                                userHeaders: userHeaders, userHeaderLen: userHeaderLen,
                                payload: payload
                            )
                        }
                    }
                }
            }}
            return off
        }
        return buf
    }

    @inline(__always)
    private static func writeOneHpubFrame(
        dst: UnsafeMutablePointer<UInt8>,
        off: inout Int,
        prefixBase: UnsafePointer<UInt8>, prefixLen: Int,
        headerBase: UnsafePointer<UInt8>, headerLen: Int,
        id: UInt64,
        idBase: UnsafePointer<UInt8>, idLen: Int,
        userHeaders: [NatsHeader], userHeaderLen: Int,
        payload: [UInt8]
    ) {
        let payloadLen = payload.count
        let hlen = headerLen &+ idLen &+ 4 &+ userHeaderLen
        let tlen = hlen &+ payloadLen
        writeHpubLine(dst: dst, off: &off, prefixBase: prefixBase, prefixLen: prefixLen, id: id, hlen: UInt64(truncatingIfNeeded: hlen), tlen: UInt64(truncatingIfNeeded: tlen))
        writeHpubHeaderBlock(dst: dst, off: &off, headerBase: headerBase, headerLen: headerLen, idBase: idBase, idLen: idLen, userHeaders: userHeaders)
        appendPayloadAndTerminator(dst: dst, off: &off, payload: payload, count: payloadLen)
    }

    @inline(__always)
    private static func writeHpubLine(
        dst: UnsafeMutablePointer<UInt8>,
        off: inout Int,
        prefixBase: UnsafePointer<UInt8>, prefixLen: Int,
        id: UInt64,
        hlen: UInt64,
        tlen: UInt64
    ) {
        dst.advanced(by: off).update(from: prefixBase, count: prefixLen)
        off &+= prefixLen
        writeBase36(dst: dst, off: &off, value: id, length: base36Length(id))
        dst[off] = Ascii.space
        off &+= 1
        writeDecimal(dst: dst, off: &off, value: hlen, length: decimalLength(hlen))
        dst[off] = Ascii.space
        off &+= 1
        writeDecimal(dst: dst, off: &off, value: tlen, length: decimalLength(tlen))
        dst[off] = Ascii.carriageReturn
        dst[off &+ 1] = Ascii.lineFeed
        off &+= 2
    }

    @inline(__always)
    private static func writeHpubHeaderBlock(
        dst: UnsafeMutablePointer<UInt8>,
        off: inout Int,
        headerBase: UnsafePointer<UInt8>, headerLen: Int,
        idBase: UnsafePointer<UInt8>, idLen: Int,
        userHeaders: [NatsHeader]
    ) {
        dst.advanced(by: off).update(from: headerBase, count: headerLen)
        off &+= headerLen
        writeMessageIdValue(dst: dst, off: &off, idBase: idBase, idLen: idLen)
        for index in 0..<userHeaders.count {
            writeUserHeader(dst: dst, off: &off, header: userHeaders[index])
        }
        dst[off] = Ascii.carriageReturn
        dst[off &+ 1] = Ascii.lineFeed
        off &+= 2
    }

    @inline(__always)
    private static func writeMessageIdValue(dst: UnsafeMutablePointer<UInt8>, off: inout Int, idBase: UnsafePointer<UInt8>, idLen: Int) {
        if idLen > 0 {
            dst.advanced(by: off).update(from: idBase, count: idLen)
            off &+= idLen
        }
        dst[off] = Ascii.carriageReturn
        dst[off &+ 1] = Ascii.lineFeed
        off &+= 2
    }

    @inline(__always)
    private static func appendPayloadAndTerminator(dst: UnsafeMutablePointer<UInt8>, off: inout Int, payload: [UInt8], count: Int) {
        if count > 0 {
            copyPayloadBytes(dst: dst, off: &off, payload: payload, count: count)
        }
        dst[off] = Ascii.carriageReturn
        dst[off &+ 1] = Ascii.lineFeed
        off &+= 2
    }

    @inline(__always)
    private static func copyPayloadBytes(dst: UnsafeMutablePointer<UInt8>, off: inout Int, payload: [UInt8], count: Int) {
        payload.withUnsafeBufferPointer { payloadPointer in
            guard let base = payloadPointer.baseAddress else { return }
            dst.advanced(by: off).update(from: base, count: count)
        }
        off &+= count
    }

    @inline(__always)
    private static func writeUserHeader(dst: UnsafeMutablePointer<UInt8>, off: inout Int, header: NatsHeader) {
        writeString(dst: dst, off: &off, value: header.name)
        dst[off] = Ascii.colon
        dst[off &+ 1] = Ascii.space
        off &+= 2
        writeString(dst: dst, off: &off, value: header.value)
        dst[off] = Ascii.carriageReturn
        dst[off &+ 1] = Ascii.lineFeed
        off &+= 2
    }

    @inline(__always)
    private static func writeString(dst: UnsafeMutablePointer<UInt8>, off: inout Int, value: String) {
        let bytes = Array(value.utf8)
        bytes.withUnsafeBufferPointer { bufferPointer in
            if let base = bufferPointer.baseAddress {
                dst.advanced(by: off).update(from: base, count: bufferPointer.count)
                off &+= bufferPointer.count
            }
        }
    }

    @inline(__always)
    private static func userHeaderBytes(of headers: [NatsHeader]) -> Int {
        var total = 0
        for index in 0..<headers.count {
            total &+= headers[index].name.utf8.count &+ 2 &+ headers[index].value.utf8.count &+ 2
        }
        return total
    }

    @inline(__always)
    static func buildAckBatch(allocator: ByteBufferAllocator, replies: [[UInt8]]) -> ByteBuffer {
        var buf = allocator.buffer(capacity: replies.count * 96)
        for reply in replies {
            buf.writeBytes(ackPrefix)
            buf.writeBytes(reply)
            buf.writeBytes(ackSuffix)
        }
        return buf
    }

    static func buildNak(reply: [UInt8]) -> [UInt8] {
        buildAckResponse(reply: reply, body: nakToken)
    }

    static func buildNak(reply: [UInt8], delayNanoseconds: Int64) -> [UInt8] {
        var body = nakToken
        body.append(contentsOf: Array(" {\"delay\":\(delayNanoseconds)}".utf8))
        return buildAckResponse(reply: reply, body: body)
    }

    static func buildTerm(reply: [UInt8]) -> [UInt8] {
        buildAckResponse(reply: reply, body: termToken)
    }

    static func buildTerm(reply: [UInt8], reason: String) -> [UInt8] {
        var body = termToken
        body.append(Ascii.space)
        body.append(contentsOf: Array(reason.utf8))
        return buildAckResponse(reply: reply, body: body)
    }

    static func buildInProgress(reply: [UInt8]) -> [UInt8] {
        buildAckResponse(reply: reply, body: inProgressToken)
    }

    private static func buildAckResponse(reply: [UInt8], body: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = []
        frame.reserveCapacity(pubOp.count &+ reply.count &+ 1 &+ maxDecimalDigitsUInt64 &+ 2 &+ body.count &+ 2)
        frame.append(contentsOf: pubOp)
        frame.append(contentsOf: reply)
        frame.append(Ascii.space)
        frame.append(contentsOf: Array(String(body.count).utf8))
        frame.append(contentsOf: NatsProtocolBytes.crlf)
        frame.append(contentsOf: body)
        frame.append(contentsOf: NatsProtocolBytes.crlf)
        return frame
    }

    static func buildAnonymousConnect() -> [UInt8] {
        let connect = #"CONNECT {"verbose":false,"pedantic":false,"tls_required":false,"lang":"swift-dx","version":"0.1","protocol":1,"headers":true,"no_responders":true}"#
        var bytes = Array(connect.utf8)
        bytes.append(contentsOf: NatsProtocolBytes.pingResponse)
        return bytes
    }

    static func buildAuthenticatedConnect(jwt: String, signature: String) -> [UInt8] {
        var connect = #"CONNECT {"verbose":false,"pedantic":false,"tls_required":false,"lang":"swift-dx","version":"0.1","protocol":1,"headers":true,"no_responders":true,"jwt":""#
        connect.append(jwt)
        connect.append(#"","sig":""#)
        connect.append(signature)
        connect.append(#""}"#)
        var bytes = Array(connect.utf8)
        bytes.append(contentsOf: NatsProtocolBytes.pingResponse)
        return bytes
    }

    private static let pubOp: [UInt8] = [Ascii.upperP, Ascii.upperU, Ascii.upperB, Ascii.space]

    private static let ackPrefix: [UInt8] = [Ascii.upperP, Ascii.upperU, Ascii.upperB, Ascii.space]
    private static let ackSuffix: [UInt8] = [
        Ascii.space, 0x34, Ascii.carriageReturn, Ascii.lineFeed,
        Ascii.plus, Ascii.upperA, Ascii.upperC, Ascii.upperK,
        Ascii.carriageReturn, Ascii.lineFeed,
    ]

    private static let nakToken: [UInt8] = Array("-NAK".utf8)
    private static let termToken: [UInt8] = Array("+TERM".utf8)
    private static let inProgressToken: [UInt8] = Array("+WPI".utf8)

    @inline(__always)
    private static func makeLinePrefix(op: [UInt8], subject: String, inboxPrefixBytes: [UInt8]) -> [UInt8] {
        let subjectBytes = Array(subject.utf8)
        var prefix: [UInt8] = []
        prefix.reserveCapacity(op.count &+ subjectBytes.count &+ 1 &+ inboxPrefixBytes.count &+ 1)
        prefix.append(contentsOf: op)
        prefix.append(contentsOf: subjectBytes)
        prefix.append(Ascii.space)
        prefix.append(contentsOf: inboxPrefixBytes)
        prefix.append(Ascii.dot)
        return prefix
    }

    @inline(__always)
    private static func pubBatchMaxBytes(prefixLen: Int, payloads: [[UInt8]]) -> Int {
        var total = 0
        for payload in payloads {
            total &+= prefixLen &+ maxBase36DigitsUInt64 &+ 1 &+ maxDecimalDigitsUInt64 &+ 2 &+ payload.count &+ 2
        }
        return total
    }

    @inline(__always)
    private static func hpubFrameMaxBytes(prefixLen: Int, headerLen: Int, idBytesLen: Int, userHeaderLen: Int, payloadLen: Int) -> Int {
        prefixLen &+ maxBase36DigitsUInt64 &+ 1 &+ maxDecimalDigitsUInt64 &+ 1 &+ maxDecimalDigitsUInt64 &+ 2
            &+ headerLen &+ idBytesLen &+ 4 &+ userHeaderLen &+ payloadLen &+ 2
    }

    @inline(__always)
    static func decimalLength(_ value: UInt64) -> Int {
        digitLength(value, radix: Radix.decimal)
    }

    @inline(__always)
    static func base36Length(_ value: UInt64) -> Int {
        digitLength(value, radix: Radix.base36)
    }

    @inline(__always)
    private static func digitLength(_ value: UInt64, radix: UInt64) -> Int {
        if value == 0 { return 1 }
        var remaining = value
        var length = 0
        while remaining > 0 {
            length &+= 1
            remaining /= radix
        }
        return length
    }

    @inline(__always)
    static func writeDecimal(dst: UnsafeMutablePointer<UInt8>, off: inout Int, value: UInt64, length: Int) {
        if value == 0 {
            dst[off] = Ascii.digitZero
            off &+= 1
            return
        }
        var remaining = value
        var pos = off &+ length &- 1
        while remaining > 0 {
            dst[pos] = UInt8(truncatingIfNeeded: remaining % Radix.decimal) &+ Ascii.digitZero
            remaining /= Radix.decimal
            pos &-= 1
        }
        off &+= length
    }

    @inline(__always)
    static func writeBase36(dst: UnsafeMutablePointer<UInt8>, off: inout Int, value: UInt64, length: Int) {
        guard value != 0 else {
            writeZeroBase36Digit(dst: dst, off: &off)
            return
        }
        emitBase36Digits(dst: dst, off: &off, value: value, length: length)
    }

    @inline(__always)
    private static func writeZeroBase36Digit(dst: UnsafeMutablePointer<UInt8>, off: inout Int) {
        dst[off] = Ascii.digitZero
        off &+= 1
    }

    @inline(__always)
    private static func emitBase36Digits(dst: UnsafeMutablePointer<UInt8>, off: inout Int, value: UInt64, length: Int) {
        var remaining = value
        var pos = off &+ length &- 1
        while remaining > 0 {
            dst[pos] = base36Digit(UInt8(truncatingIfNeeded: remaining % Radix.base36))
            remaining /= Radix.base36
            pos &-= 1
        }
        off &+= length
    }

    @inline(__always)
    private static func base36Digit(_ digitValue: UInt8) -> UInt8 {
        digitValue < 10 ? digitValue &+ Ascii.digitZero : digitValue &- 10 &+ Ascii.lowerA
    }
}
