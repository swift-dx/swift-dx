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

// Incremental RESP2 parser. It scans length prefixes and integers byte-by-byte
// through the receive buffer's view, and extracts bulk/simple payloads as
// zero-copy `ByteBuffer` slices (`getSlice`) that share the receive buffer's
// storage rather than allocating a `[UInt8]` per value. An array reply of N
// elements therefore costs N shared-storage references rather than N
// allocations, which is what lets array-shaped replies (geospatial results,
// range scans, filters) beat a hand-written C client. Parsing is partial-frame
// safe: an incomplete frame returns `.needMore` without consuming.
struct RESPParser {

    enum Outcome: Equatable {

        case complete(RESPValue, bytesConsumed: Int)
        case needMore
    }

    private enum Step {

        case value(RESPValue)
        case needMore
    }

    private enum LineScan {

        case found(carriageReturnIndex: Int)
        case needMore
    }

    private enum SlotStep {

        case slot(RedisReplyArray.Element)
        case needMore
    }

    enum ArrayOutcome: Equatable {

        case complete(RedisReplyArray, bytesConsumed: Int)
        case needMore
    }

    let source: ByteBuffer
    let view: ByteBufferView
    let depthLimit: Int
    let maxBulkBytes: Int

    init(buffer: ByteBuffer, depthLimit: Int, maxBulkBytes: Int) {
        self.source = buffer
        self.view = buffer.readableBytesView
        self.depthLimit = depthLimit
        self.maxBulkBytes = maxBulkBytes
    }

    func parse(from startOffset: Int) throws(RedisError) -> Outcome {
        var cursor = startOffset
        switch try parseValue(at: &cursor, depth: 0) {
        case .needMore: return .needMore
        case .value(let value): return .complete(value, bytesConsumed: cursor - startOffset)
        }
    }

    enum ArrayHeader: Equatable {

        case header(count: Int, elementsStart: Int)
        case nullArray(consumedUpTo: Int)
        case needMore
    }

    // Reads an array header. The caller must have confirmed the byte at
    // `startOffset` is the array marker `*` and is within bounds (the inbound
    // handler checks both before calling); this keeps the hot path free of a
    // redundant re-check.
    func beginReplyArray(from startOffset: Int) throws(RedisError) -> ArrayHeader {
        guard case .found(let carriageReturn) = try scanLine(from: startOffset + 1) else { return .needMore }
        let declared = try parseSignedInteger(from: startOffset + 1, to: carriageReturn)
        guard declared >= 0 else { return .nullArray(consumedUpTo: carriageReturn + 2) }
        return .header(count: Int(declared), elementsStart: carriageReturn + 2)
    }

    // Resumes parsing array elements where a previous call left off. `cursor` is
    // the absolute index of the next element to read and `remaining` the number
    // still to read; both carry across reads so an element is scanned only once.
    // Element offsets are recorded relative to `base` (the array frame start), so
    // the finished `RedisReplyArray` slices its single backing buffer by offset.
    func resumeReplyArrayElements(remaining: inout Int, elements: inout [RedisReplyArray.Element], cursor: inout Int, base: Int) throws(RedisError) -> Bool {
        while remaining > 0 {
            switch try readReplyElement(base: base, cursor: &cursor) {
            case .needMore: return false
            case .slot(let slot):
                elements.append(slot)
                remaining &-= 1
            }
        }
        return true
    }

    func sliceFrame(from start: Int, to end: Int) throws(RedisError) -> ByteBuffer {
        guard let storage = source.getSlice(at: start, length: end - start) else {
            throw RedisError.protocolError(reason: "reply frame slice out of bounds")
        }
        return storage
    }

    func parseReplyArray(from startOffset: Int) throws(RedisError) -> ArrayOutcome {
        guard startOffset < view.endIndex, view[startOffset] == Ascii.asterisk else {
            throw RedisError.unexpectedResponseType(expected: "array", actual: "non-array reply")
        }
        guard case .found(let carriageReturn) = try scanLine(from: startOffset + 1) else { return .needMore }
        let declared = try parseSignedInteger(from: startOffset + 1, to: carriageReturn)
        var cursor = carriageReturn + 2
        return try readReplyElements(count: declared, base: startOffset, cursor: &cursor)
    }

    private func readReplyElements(count: Int64, base: Int, cursor: inout Int) throws(RedisError) -> ArrayOutcome {
        let total = max(Int(count), 0)
        var slots = [RedisReplyArray.Element]()
        slots.reserveCapacity(min(total, 65536))
        for _ in 0..<total {
            switch try readReplyElement(base: base, cursor: &cursor) {
            case .needMore: return .needMore
            case .slot(let slot): slots.append(slot)
            }
        }
        return finishReplyArray(base: base, end: cursor, slots: slots)
    }

    private func readReplyElement(base: Int, cursor: inout Int) throws(RedisError) -> SlotStep {
        guard cursor < view.endIndex else { return .needMore }
        switch view[cursor] {
        case Ascii.dollar: return try readBulkSlot(base: base, cursor: &cursor)
        case Ascii.plus: return try readLineSlot(base: base, cursor: &cursor, isError: false)
        case Ascii.hyphen: return try readLineSlot(base: base, cursor: &cursor, isError: true)
        case Ascii.colon: return try readIntegerSlot(cursor: &cursor)
        case Ascii.asterisk: return try readNestedSlot(cursor: &cursor)
        default: throw RedisError.protocolError(reason: "unknown RESP type byte \(view[cursor])")
        }
    }

    private func readBulkSlot(base: Int, cursor: inout Int) throws(RedisError) -> SlotStep {
        guard case .found(let carriageReturn) = try scanLine(from: cursor + 1) else { return .needMore }
        let declared = try parseSignedInteger(from: cursor + 1, to: carriageReturn)
        guard declared >= 0 else { cursor = carriageReturn + 2; return .slot(.null) }
        return try readBulkSlotPayload(base: base, declared: declared, bodyStart: carriageReturn + 2, cursor: &cursor)
    }

    private func readBulkSlotPayload(base: Int, declared: Int64, bodyStart: Int, cursor: inout Int) throws(RedisError) -> SlotStep {
        try enforceBulkLimit(declared)
        let frameEnd = bodyStart + Int(declared) + 2
        guard frameEnd <= view.endIndex else { return .needMore }
        try verifyTerminator(at: bodyStart + Int(declared))
        cursor = frameEnd
        return .slot(.bulkString(offset: bodyStart - base, length: Int(declared)))
    }

    private func readLineSlot(base: Int, cursor: inout Int, isError: Bool) throws(RedisError) -> SlotStep {
        let contentStart = cursor + 1
        guard case .found(let carriageReturn) = try scanLine(from: contentStart) else { return .needMore }
        cursor = carriageReturn + 2
        guard isError else { return .slot(.simpleString(offset: contentStart - base, length: carriageReturn - contentStart)) }
        return .slot(errorSlot(from: contentStart, to: carriageReturn))
    }

    private func readIntegerSlot(cursor: inout Int) throws(RedisError) -> SlotStep {
        let contentStart = cursor + 1
        guard case .found(let carriageReturn) = try scanLine(from: contentStart) else { return .needMore }
        let value = try parseSignedInteger(from: contentStart, to: carriageReturn)
        cursor = carriageReturn + 2
        return .slot(.integer(value))
    }

    private func readNestedSlot(cursor: inout Int) throws(RedisError) -> SlotStep {
        switch try parseReplyArray(from: cursor) {
        case .needMore: return .needMore
        case .complete(let nested, let bytesConsumed):
            cursor += bytesConsumed
            return .slot(.nested(nested))
        }
    }

    private func finishReplyArray(base: Int, end: Int, slots: [RedisReplyArray.Element]) -> ArrayOutcome {
        guard let storage = source.getSlice(at: base, length: end - base) else { return .needMore }
        return .complete(RedisReplyArray(storage: storage, elements: slots), bytesConsumed: end - base)
    }

    private func errorSlot(from start: Int, to end: Int) -> RedisReplyArray.Element {
        let text = String(decoding: view[start..<end], as: UTF8.self)
        let parts = text.split(separator: " ", maxSplits: 1)
        return .serverError(prefix: parts.first.map(String.init) ?? text, message: parts.count > 1 ? String(parts[1]) : "")
    }

    @inline(__always)
    private func parseValue(at cursor: inout Int, depth: Int) throws(RedisError) -> Step {
        guard cursor < view.endIndex else { return .needMore }
        switch view[cursor] {
        case Ascii.plus: return try parseSimpleString(at: &cursor)
        case Ascii.hyphen: return try parseError(at: &cursor)
        case Ascii.colon: return try parseInteger(at: &cursor)
        case Ascii.dollar: return try parseBulkString(at: &cursor)
        case Ascii.asterisk: return try parseArray(at: &cursor, depth: depth)
        default: throw RedisError.protocolError(reason: "unknown RESP type byte \(view[cursor])")
        }
    }

    @inline(__always)
    private func parseSimpleString(at cursor: inout Int) throws(RedisError) -> Step {
        let contentStart = cursor + 1
        guard case .found(let carriageReturn) = try scanLine(from: contentStart) else { return .needMore }
        cursor = carriageReturn + 2
        return .value(.simpleString(try slice(at: contentStart, length: carriageReturn - contentStart)))
    }

    @inline(__always)
    private func parseError(at cursor: inout Int) throws(RedisError) -> Step {
        let contentStart = cursor + 1
        guard case .found(let carriageReturn) = try scanLine(from: contentStart) else { return .needMore }
        cursor = carriageReturn + 2
        return .value(makeError(from: contentStart, to: carriageReturn))
    }

    @inline(__always)
    private func parseInteger(at cursor: inout Int) throws(RedisError) -> Step {
        let contentStart = cursor + 1
        guard case .found(let carriageReturn) = try scanLine(from: contentStart) else { return .needMore }
        let value = try parseSignedInteger(from: contentStart, to: carriageReturn)
        cursor = carriageReturn + 2
        return .value(.integer(value))
    }

    @inline(__always)
    private func parseBulkString(at cursor: inout Int) throws(RedisError) -> Step {
        let lengthStart = cursor + 1
        guard case .found(let carriageReturn) = try scanLine(from: lengthStart) else { return .needMore }
        let declared = try parseSignedInteger(from: lengthStart, to: carriageReturn)
        return try bulkBody(declaredLength: declared, bodyStart: carriageReturn + 2, cursor: &cursor)
    }

    @inline(__always)
    private func bulkBody(declaredLength: Int64, bodyStart: Int, cursor: inout Int) throws(RedisError) -> Step {
        guard declaredLength >= 0 else { return finishNull(consumedUpTo: bodyStart, cursor: &cursor) }
        try enforceBulkLimit(declaredLength)
        return try readBulkPayload(length: Int(declaredLength), bodyStart: bodyStart, cursor: &cursor)
    }

    @inline(__always)
    private func readBulkPayload(length: Int, bodyStart: Int, cursor: inout Int) throws(RedisError) -> Step {
        let frameEnd = bodyStart + length + 2
        guard frameEnd <= view.endIndex else { return .needMore }
        try verifyTerminator(at: bodyStart + length)
        cursor = frameEnd
        return .value(.bulkString(try slice(at: bodyStart, length: length)))
    }

    @inline(__always)
    private func slice(at start: Int, length: Int) throws(RedisError) -> ByteBuffer {
        guard let payload = source.getSlice(at: start, length: length) else {
            throw RedisError.protocolError(reason: "payload slice out of bounds")
        }
        return payload
    }

    @inline(__always)
    private func verifyTerminator(at index: Int) throws(RedisError) {
        guard view[index] == Ascii.carriageReturn, view[index + 1] == Ascii.lineFeed else {
            throw RedisError.protocolError(reason: "bulk payload not terminated by CRLF")
        }
    }

    private func parseArray(at cursor: inout Int, depth: Int) throws(RedisError) -> Step {
        try enforceDepth(depth)
        let lengthStart = cursor + 1
        guard case .found(let carriageReturn) = try scanLine(from: lengthStart) else { return .needMore }
        let declared = try parseSignedInteger(from: lengthStart, to: carriageReturn)
        return try arrayBody(count: declared, elementsStart: carriageReturn + 2, depth: depth, cursor: &cursor)
    }

    private func arrayBody(count: Int64, elementsStart: Int, depth: Int, cursor: inout Int) throws(RedisError) -> Step {
        guard count >= 0 else { return finishNull(consumedUpTo: elementsStart, cursor: &cursor) }
        return try readElements(count: Int(count), elementsStart: elementsStart, depth: depth, cursor: &cursor)
    }

    private func readElements(count: Int, elementsStart: Int, depth: Int, cursor: inout Int) throws(RedisError) -> Step {
        var elements = [RESPValue]()
        elements.reserveCapacity(min(count, 65536))
        var elementCursor = elementsStart
        for _ in 0..<count {
            switch try parseValue(at: &elementCursor, depth: depth + 1) {
            case .needMore: return .needMore
            case .value(let value): elements.append(value)
            }
        }
        cursor = elementCursor
        return .value(.array(elements))
    }

    @inline(__always)
    private func finishNull(consumedUpTo: Int, cursor: inout Int) -> Step {
        cursor = consumedUpTo
        return .value(.null)
    }

    @inline(__always)
    private func scanLine(from start: Int) throws(RedisError) -> LineScan {
        guard let carriageReturn = view[start...].firstIndex(of: Ascii.carriageReturn) else { return .needMore }
        return try lineFeedFollows(carriageReturnIndex: carriageReturn)
    }

    @inline(__always)
    private func lineFeedFollows(carriageReturnIndex: Int) throws(RedisError) -> LineScan {
        let lineFeedIndex = carriageReturnIndex + 1
        guard lineFeedIndex < view.endIndex else { return .needMore }
        guard view[lineFeedIndex] == Ascii.lineFeed else {
            throw RedisError.protocolError(reason: "RESP line CR not followed by LF")
        }
        return .found(carriageReturnIndex: carriageReturnIndex)
    }

    private func enforceBulkLimit(_ declared: Int64) throws(RedisError) {
        guard declared <= Int64(maxBulkBytes) else {
            throw RedisError.malformedLength(reason: "bulk length \(declared) exceeds limit \(maxBulkBytes)")
        }
    }

    private func enforceDepth(_ depth: Int) throws(RedisError) {
        guard depth < depthLimit else {
            throw RedisError.responseDepthLimitExceeded(limit: depthLimit)
        }
    }

    private func makeError(from start: Int, to end: Int) -> RESPValue {
        let text = String(decoding: view[start..<end], as: UTF8.self)
        let parts = text.split(separator: " ", maxSplits: 1)
        return .error(prefix: parts.first.map(String.init) ?? text, message: parts.count > 1 ? String(parts[1]) : "")
    }

    @inline(__always)
    private func parseSignedInteger(from start: Int, to end: Int) throws(RedisError) -> Int64 {
        guard start < end else { throw RedisError.integerConversionFailed(text: "empty integer") }
        guard view[start] == Ascii.hyphen else { return try parseDigits(from: start, to: end) }
        return try negate(parseDigits(from: start + 1, to: end))
    }

    @inline(__always)
    private func negate(_ value: Int64) throws(RedisError) -> Int64 {
        let (result, overflow) = Int64(0).subtractingReportingOverflow(value)
        guard !overflow else { throw RedisError.integerConversionFailed(text: "integer overflow") }
        return result
    }

    @inline(__always)
    private func parseDigits(from start: Int, to end: Int) throws(RedisError) -> Int64 {
        guard start < end else { throw RedisError.integerConversionFailed(text: "missing digits") }
        var value: Int64 = 0
        var index = start
        while index < end {
            value = try appendDigit(value, byte: view[index])
            index &+= 1
        }
        return value
    }

    @inline(__always)
    private func appendDigit(_ value: Int64, byte: UInt8) throws(RedisError) -> Int64 {
        guard byte >= Ascii.digitZero, byte <= Ascii.digitNine else {
            throw RedisError.integerConversionFailed(text: "non-digit byte in integer")
        }
        return try scaleAndAdd(value, digit: Int64(byte &- Ascii.digitZero))
    }

    @inline(__always)
    private func scaleAndAdd(_ value: Int64, digit: Int64) throws(RedisError) -> Int64 {
        let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: 10)
        let (sum, addOverflow) = scaled.addingReportingOverflow(digit)
        guard !scaleOverflow, !addOverflow else { throw RedisError.integerConversionFailed(text: "integer overflow") }
        return sum
    }
}
