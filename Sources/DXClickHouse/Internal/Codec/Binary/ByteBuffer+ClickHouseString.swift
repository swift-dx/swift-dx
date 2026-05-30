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

extension ByteBuffer {

    // ClickHouse caps string field reads at one gigabyte by default to bound
    // memory pressure from a malicious or buggy peer that advertises a huge
    // length prefix. Production callers can lower this further via
    // readClickHouseString(maxLength:).
    static let clickhouseStringDefaultLimit = 1 << 30

    mutating func readClickHouseString(maxLength: Int = ByteBuffer.clickhouseStringDefaultLimit) throws -> String {
        let declared = try readClickHouseUVarInt()
        let length = try validateDeclaredStringLength(declared: declared, maxLength: maxLength)
        return try readUTF8StringOfLength(length)
    }

    private func validateDeclaredStringLength(declared: UInt64, maxLength: Int) throws -> Int {
        if declared > UInt64(maxLength) {
            throw ClickHouseError.stringLengthExceedsLimit(declared: declared, limit: maxLength)
        }
        if declared > UInt64(readableBytes) {
            throw ClickHouseError.stringLengthExceedsBuffer(declared: declared, available: readableBytes)
        }
        return Int(declared)
    }

    private mutating func readUTF8StringOfLength(_ length: Int) throws -> String {
        if length == 0 {
            return ""
        }
        guard let string = readString(length: length) else {
            throw ClickHouseError.invalidUTF8
        }
        return string
    }

    mutating func writeClickHouseString(_ value: String) {
        let utf8 = value.utf8
        writeClickHouseUVarInt(UInt64(utf8.count))
        writeBytes(utf8)
    }

    // Single-pass arena reader: walks the wire bytes once, copies the
    // string payloads into `arena`, and records absolute byte offsets
    // (length = rows + 1) into `offsets`. Used by the SELECT column
    // decoder to avoid per-row Swift `String` allocations during the
    // wire-decode pass — every `String` heap alloc is deferred until
    // a caller actually inspects the column body. This mirrors the
    // arena+view pattern that clickhouse-cpp uses (`ColumnString::Block`
    // + `std::vector<std::string_view>`), modulo Swift's lack of a
    // String view type — the materialisation happens on demand at the
    // column's `values` boundary.
    mutating func readClickHouseStringsArena(
        rows: Int,
        arena: inout [UInt8],
        offsets: inout [Int],
        maxLength: Int = ByteBuffer.clickhouseStringDefaultLimit
    ) throws {
        let totalBytes = Self.sumStringPayloadBytes(buffer: self, rows: rows, maxLength: maxLength)
        let outcomeAndConsumed: (BulkStringReadOutcome, Int)
        if arena.isEmpty && offsets.isEmpty {
            outcomeAndConsumed = readArenaFresh(rows: rows, totalBytes: totalBytes, maxLength: maxLength, arena: &arena, offsets: &offsets)
        } else {
            outcomeAndConsumed = readArenaAppend(rows: rows, totalBytes: totalBytes, maxLength: maxLength, arena: &arena, offsets: &offsets)
        }
        switch outcomeAndConsumed.0 {
        case .completed:
            moveReaderIndex(forwardBy: outcomeAndConsumed.1)
        case .failed(let error):
            throw error
        }
    }

    private mutating func readArenaFresh(
        rows: Int, totalBytes: Int, maxLength: Int,
        arena: inout [UInt8], offsets: inout [Int]
    ) -> (BulkStringReadOutcome, Int) {
        var consumedBytes = 0
        var outcome: BulkStringReadOutcome = .completed
        var capturedOffsetsCount = 0
        arena = [UInt8](unsafeUninitializedCapacity: totalBytes) { arenaBuffer, arenaInitialisedCount in
            guard let arenaPointer = arenaBuffer.baseAddress else {
                arenaInitialisedCount = 0
                return
            }
            offsets = [Int](unsafeUninitializedCapacity: rows + 1) { offsetsBuffer, offsetsInitialisedCount in
                guard let offsetsPointer = offsetsBuffer.baseAddress else {
                    offsetsInitialisedCount = 0
                    return
                }
                self.withUnsafeReadableBytes { rawBytes in
                    guard let base = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    outcome = Self.bulkReadStringsArenaIntoRaw(
                        base: base,
                        limit: rawBytes.count,
                        rows: rows,
                        maxLength: maxLength,
                        arenaPointer: arenaPointer,
                        offsetsPointer: offsetsPointer,
                        consumedBytes: &consumedBytes
                    )
                }
                offsetsInitialisedCount = outcome.completedCountOrZero(success: rows + 1)
                capturedOffsetsCount = offsetsInitialisedCount
            }
            arenaInitialisedCount = outcome.completedCountOrZero(success: totalBytes)
        }
        if capturedOffsetsCount == 0 {
            offsets = []
        }
        return (outcome, consumedBytes)
    }

    private mutating func readArenaAppend(
        rows: Int, totalBytes: Int, maxLength: Int,
        arena: inout [UInt8], offsets: inout [Int]
    ) -> (BulkStringReadOutcome, Int) {
        var consumedBytes = 0
        var outcome: BulkStringReadOutcome = .completed
        offsets.reserveCapacity(offsets.count + rows + 1)
        if offsets.isEmpty {
            offsets.append(0)
        }
        let arenaBase = arena.count
        arena.append(contentsOf: repeatElement(UInt8(0), count: totalBytes))
        withUnsafeReadableBytes { rawBytes in
            guard let base = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            arena.withUnsafeMutableBufferPointer { arenaBuffer in
                guard let arenaPointer = arenaBuffer.baseAddress else { return }
                outcome = Self.bulkReadStringsArenaInto(
                    base: base,
                    limit: rawBytes.count,
                    rows: rows,
                    maxLength: maxLength,
                    arenaPointer: arenaPointer + arenaBase,
                    arenaBase: arenaBase,
                    offsets: &offsets,
                    consumedBytes: &consumedBytes
                )
            }
        }
        return (outcome, consumedBytes)
    }

    private static func bulkReadStringsArenaIntoRaw(
        base: UnsafePointer<UInt8>,
        limit: Int,
        rows: Int,
        maxLength: Int,
        arenaPointer: UnsafeMutablePointer<UInt8>,
        offsetsPointer: UnsafeMutablePointer<Int>,
        consumedBytes: inout Int
    ) -> BulkStringReadOutcome {
        offsetsPointer[0] = 0
        var state = BulkArenaScanState(bytesRead: 0, arenaWriteCount: 0)
        for rowIndex in 0..<rows {
            switch advanceArenaScanStep(
                base: base, limit: limit, maxLength: maxLength,
                arenaPointer: arenaPointer, state: &state
            ) {
            case .failed(let error): return .failed(error)
            case .completed: offsetsPointer[rowIndex + 1] = state.arenaWriteCount
            }
        }
        consumedBytes = state.bytesRead
        return .completed
    }

    private static func bulkReadStringsArenaInto(
        base: UnsafePointer<UInt8>,
        limit: Int,
        rows: Int,
        maxLength: Int,
        arenaPointer: UnsafeMutablePointer<UInt8>,
        arenaBase: Int,
        offsets: inout [Int],
        consumedBytes: inout Int
    ) -> BulkStringReadOutcome {
        var state = BulkArenaScanState(bytesRead: 0, arenaWriteCount: 0)
        for _ in 0..<rows {
            switch advanceArenaScanStep(
                base: base, limit: limit, maxLength: maxLength,
                arenaPointer: arenaPointer, state: &state
            ) {
            case .failed(let error): return .failed(error)
            case .completed: offsets.append(arenaBase + state.arenaWriteCount)
            }
        }
        consumedBytes = state.bytesRead
        return .completed
    }

    // One iteration of the bulk-arena scan. Returns `.completed` when
    // the row was decoded into the arena and the state was advanced;
    // `.failed` carries the typed error for the bad row.
    private static func advanceArenaScanStep(
        base: UnsafePointer<UInt8>,
        limit: Int,
        maxLength: Int,
        arenaPointer: UnsafeMutablePointer<UInt8>,
        state: inout BulkArenaScanState
    ) -> BulkStringReadOutcome {
        switch readUVarIntAt(base: base, offset: state.bytesRead, limit: limit) {
        case .failed(let error): return .failed(error)
        case .parsed(let declared, let consumed):
            return commitArenaScanStep(
                base: base, limit: limit, maxLength: maxLength,
                declared: declared, consumed: consumed,
                arenaPointer: arenaPointer, state: &state
            )
        }
    }

    private static func commitArenaScanStep(
        base: UnsafePointer<UInt8>,
        limit: Int,
        maxLength: Int,
        declared: UInt64,
        consumed: Int,
        arenaPointer: UnsafeMutablePointer<UInt8>,
        state: inout BulkArenaScanState
    ) -> BulkStringReadOutcome {
        if declared > UInt64(maxLength) {
            return .failed(.stringLengthExceedsLimit(declared: declared, limit: maxLength))
        }
        let payloadOffset = state.bytesRead + consumed
        let payloadLength = Int(declared)
        if payloadOffset + payloadLength > limit {
            return .failed(.stringLengthExceedsBuffer(declared: declared, available: limit - payloadOffset))
        }
        copyPayloadIntoArena(
            base: base, payloadOffset: payloadOffset, payloadLength: payloadLength,
            arenaPointer: arenaPointer, state: &state
        )
        state.bytesRead = payloadOffset + payloadLength
        return .completed
    }

    private static func copyPayloadIntoArena(
        base: UnsafePointer<UInt8>,
        payloadOffset: Int,
        payloadLength: Int,
        arenaPointer: UnsafeMutablePointer<UInt8>,
        state: inout BulkArenaScanState
    ) {
        if payloadLength <= 0 { return }
        (arenaPointer + state.arenaWriteCount).update(
            from: base + payloadOffset,
            count: payloadLength
        )
        state.arenaWriteCount += payloadLength
    }

    private struct BulkArenaScanState {

        var bytesRead: Int
        var arenaWriteCount: Int
    }

    private static func sumStringPayloadBytes(buffer: ByteBuffer, rows: Int, maxLength: Int) -> Int {
        var total = 0
        buffer.withUnsafeReadableBytes { rawBytes in
            guard let base = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let limit = rawBytes.count
            var offset = 0
            for _ in 0..<rows {
                switch readUVarIntAt(base: base, offset: offset, limit: limit) {
                case .failed: return
                case .parsed(let declared, let consumed):
                    if declared > UInt64(maxLength) { return }
                    let payloadLength = Int(declared)
                    let nextOffset = offset + consumed + payloadLength
                    if nextOffset > limit { return }
                    total += payloadLength
                    offset = nextOffset
                }
            }
        }
        return total
    }

    private static func bulkReadStringsArena(
        base: UnsafePointer<UInt8>,
        limit: Int,
        rows: Int,
        maxLength: Int,
        arena: inout [UInt8],
        offsets: inout [Int],
        arenaWriteCount: inout Int,
        consumedBytes: inout Int
    ) -> BulkStringReadOutcome {
        var bytesRead = 0
        for _ in 0..<rows {
            switch readOneArenaString(
                base: base, limit: limit, offset: bytesRead, maxLength: maxLength,
                arena: &arena, offsets: &offsets, arenaWriteCount: &arenaWriteCount
            ) {
            case .failed(let error): return .failed(error)
            case .advanced(let nextOffset): bytesRead = nextOffset
            }
        }
        consumedBytes = bytesRead
        return .completed
    }

    @inline(__always)
    private static func readOneArenaString(
        base: UnsafePointer<UInt8>,
        limit: Int,
        offset: Int,
        maxLength: Int,
        arena: inout [UInt8],
        offsets: inout [Int],
        arenaWriteCount: inout Int
    ) -> OneStringOutcome {
        switch readUVarIntAt(base: base, offset: offset, limit: limit) {
        case .failed(let error): return .failed(error)
        case .parsed(let declared, let consumed):
            return appendArenaPayload(
                base: base, limit: limit,
                offset: offset + consumed, declared: declared, maxLength: maxLength,
                arena: &arena, offsets: &offsets, arenaWriteCount: &arenaWriteCount
            )
        }
    }

    @inline(__always)
    private static func appendArenaPayload(
        base: UnsafePointer<UInt8>,
        limit: Int,
        offset: Int,
        declared: UInt64,
        maxLength: Int,
        arena: inout [UInt8],
        offsets: inout [Int],
        arenaWriteCount: inout Int
    ) -> OneStringOutcome {
        switch validateDeclaredLength(declared: declared, maxLength: maxLength, offset: offset, limit: limit) {
        case .invalid(let error): return .failed(error)
        case .valid:
            let payloadLength = Int(declared)
            if payloadLength > 0 {
                let slice = UnsafeBufferPointer(start: base + offset, count: payloadLength)
                arena.append(contentsOf: slice)
                arenaWriteCount += payloadLength
            }
            offsets.append(arenaWriteCount)
            return .advanced(offset + payloadLength)
        }
    }

    mutating func readClickHouseStrings(rows: Int, maxLength: Int = ByteBuffer.clickhouseStringDefaultLimit) throws -> [String] {
        // Each string needs at least its varint length prefix (≥1 byte),
        // so a hostile `rows` greater than `readableBytes` cannot succeed
        // and must not pre-allocate. The actual loop still throws
        // `truncatedBuffer` when bytes run out.
        let reserve = min(rows, readableBytes)
        var result: [String] = []
        result.reserveCapacity(reserve)
        // Single-pass bulk reader: one `withUnsafeReadableBytes` for the
        // entire column. Skips per-row `swift_beginAccess` on the buffer
        // and reads varint + payload directly from the raw pointer. The
        // outer ByteBuffer's reader index moves once at the end via
        // `moveReaderIndex` instead of N times. On a typical 100k-row
        // String column this cuts the per-string runtime overhead by
        // collapsing 2N exclusivity checks down to 1.
        var consumedBytes = 0
        var outcome: BulkStringReadOutcome = .completed
        withUnsafeReadableBytes { rawBytes in
            guard let base = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            outcome = Self.bulkReadStrings(
                base: base,
                limit: rawBytes.count,
                rows: rows,
                maxLength: maxLength,
                result: &result,
                consumedBytes: &consumedBytes
            )
        }
        switch outcome {
        case .completed:
            moveReaderIndex(forwardBy: consumedBytes)
            return result
        case .failed(let error):
            throw error
        }
    }

    enum BulkStringReadOutcome {

        case completed
        case failed(ClickHouseError)

        func completedCountOrZero(success: Int) -> Int {
            if case .completed = self { return success }
            return 0
        }
    }

    private static func bulkReadStrings(
        base: UnsafePointer<UInt8>,
        limit: Int,
        rows: Int,
        maxLength: Int,
        result: inout [String],
        consumedBytes: inout Int
    ) -> BulkStringReadOutcome {
        var bytesRead = 0
        for _ in 0..<rows {
            switch readOneBulkString(base: base, limit: limit, offset: bytesRead, maxLength: maxLength, result: &result) {
            case .failed(let error): return .failed(error)
            case .advanced(let nextOffset): bytesRead = nextOffset
            }
        }
        consumedBytes = bytesRead
        return .completed
    }

    private enum OneStringOutcome {

        case advanced(Int)
        case failed(ClickHouseError)

    }

    @inline(__always)
    private static func readOneBulkString(
        base: UnsafePointer<UInt8>,
        limit: Int,
        offset: Int,
        maxLength: Int,
        result: inout [String]
    ) -> OneStringOutcome {
        switch readUVarIntAt(base: base, offset: offset, limit: limit) {
        case .failed(let error): return .failed(error)
        case .parsed(let declared, let consumed):
            return appendStringPayload(base: base, limit: limit, offset: offset + consumed, declared: declared, maxLength: maxLength, result: &result)
        }
    }

    @inline(__always)
    private static func appendStringPayload(
        base: UnsafePointer<UInt8>,
        limit: Int,
        offset: Int,
        declared: UInt64,
        maxLength: Int,
        result: inout [String]
    ) -> OneStringOutcome {
        switch validateDeclaredLength(declared: declared, maxLength: maxLength, offset: offset, limit: limit) {
        case .invalid(let error): return .failed(error)
        case .valid:
            let payloadLength = Int(declared)
            result.append(makeStringFromSlice(base: base + offset, length: payloadLength))
            return .advanced(offset + payloadLength)
        }
    }

    private enum DeclaredLengthValidation {

        case valid
        case invalid(ClickHouseError)

    }

    @inline(__always)
    private static func validateDeclaredLength(declared: UInt64, maxLength: Int, offset: Int, limit: Int) -> DeclaredLengthValidation {
        if declared > UInt64(maxLength) {
            return .invalid(.stringLengthExceedsLimit(declared: declared, limit: maxLength))
        }
        if offset + Int(declared) > limit {
            return .invalid(.stringLengthExceedsBuffer(declared: declared, available: limit - offset))
        }
        return .valid
    }

    @inline(__always)
    private static func makeStringFromSlice(base: UnsafePointer<UInt8>, length: Int) -> String {
        if length == 0 { return "" }
        let slice = UnsafeRawBufferPointer(start: base, count: length)
        return String(decoding: slice, as: Unicode.UTF8.self)
    }

    enum InlineUVarIntOutcome {

        case parsed(value: UInt64, bytes: Int)
        case failed(ClickHouseError)

    }

    @inline(__always)
    private static func readUVarIntAt(base: UnsafePointer<UInt8>, offset: Int, limit: Int) -> InlineUVarIntOutcome {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var byteIndex = 0
        let maxBytes = ByteBuffer.clickhouseUVarIntMaxBytes
        while byteIndex < maxBytes {
            switch stepUVarIntByte(base: base, offset: offset + byteIndex, limit: limit, value: value, shift: shift, byteIndex: byteIndex) {
            case .failed(let error): return .failed(error)
            case .terminal(let parsed): return .parsed(value: parsed, bytes: byteIndex + 1)
            case .continuing(let next, let nextShift):
                value = next
                shift = nextShift
                byteIndex += 1
            }
        }
        return .failed(.uvarintOverflow)
    }

    private enum UVarIntStep {

        case continuing(value: UInt64, shift: UInt64)
        case terminal(value: UInt64)
        case failed(ClickHouseError)

    }

    @inline(__always)
    private static func stepUVarIntByte(
        base: UnsafePointer<UInt8>,
        offset: Int,
        limit: Int,
        value: UInt64,
        shift: UInt64,
        byteIndex: Int
    ) -> UVarIntStep {
        if offset >= limit {
            return .failed(.uvarintIncomplete)
        }
        return classifyUVarIntByte(byte: base[offset], value: value, shift: shift, byteIndex: byteIndex)
    }

    @inline(__always)
    private static func classifyUVarIntByte(byte: UInt8, value: UInt64, shift: UInt64, byteIndex: Int) -> UVarIntStep {
        if byte >= 0x80 {
            return .continuing(value: value | (UInt64(byte & 0x7F) << shift), shift: shift + 7)
        }
        if byteIndex == ByteBuffer.clickhouseUVarIntMaxBytes - 1, byte > 1 {
            return .failed(.uvarintOverflow)
        }
        return .terminal(value: value | (UInt64(byte) << shift))
    }

    mutating func writeClickHouseStrings(_ values: [String]) {
        for value in values {
            writeClickHouseString(value)
        }
    }

}
