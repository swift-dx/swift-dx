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

// LZ4 block format decoder. The block is a sequence of "sequences",
// each of the shape:
//
//     [token : UInt8]
//     [optional literal-length extension bytes]
//     [literal bytes]
//     [match offset : UInt16 little-endian]
//     [optional match-length extension bytes]
//
// `token`'s high nibble seeds the literal length, low nibble seeds the
// match length. A nibble value of 15 signals that more length bytes
// follow: each adds 0..255 to the running total, and the run ends when
// a byte is < 255.
//
// The last sequence omits the offset+match section: detected at
// decode time when the input is exhausted after the literal copy.
//
// Match copy is intentionally byte-by-byte rather than bulk: an offset
// smaller than the match length is the documented LZ4 way to express
// run-length encoding (e.g. offset=1, length=100 means "repeat the
// previous byte 100 times"). A `memcpy` would read source bytes
// before they are written and produce wrong output.
enum ClickHouseLZ4 {

    static func decompress(
        from compressed: inout ByteBuffer,
        uncompressedSize: Int
    ) throws -> ByteBuffer {
        var output = ByteBuffer()
        output.reserveCapacity(uncompressedSize)

        while compressed.readableBytes > 0 {
            try decodeOneSequence(source: &compressed, destination: &output, cap: uncompressedSize)
        }

        guard output.readableBytes == uncompressedSize else {
            throw ClickHouseError.lz4DecompressedSizeMismatch(
                expected: uncompressedSize,
                actual: output.readableBytes
            )
        }
        return output
    }

    private static func decodeOneSequence(
        source: inout ByteBuffer,
        destination: inout ByteBuffer,
        cap: Int
    ) throws {
        let token = try readSequenceToken(source: &source)
        try decodeLiteralsSection(token: token, source: &source, destination: &destination, cap: cap)
        if source.readableBytes == 0 { return }
        try decodeMatchSection(token: token, source: &source, destination: &destination, cap: cap)
    }

    @inline(__always)
    private static func readSequenceToken(source: inout ByteBuffer) throws -> UInt8 {
        guard let token = source.readInteger(as: UInt8.self) else {
            throw ClickHouseError.lz4MalformedBlock("missing sequence token")
        }
        return token
    }

    @inline(__always)
    private static func decodeLiteralsSection(token: UInt8, source: inout ByteBuffer, destination: inout ByteBuffer, cap: Int) throws {
        let literalLength = try readVariableLength(initial: Int(token >> 4), source: &source)
        try ensureCapAvailable(written: destination.writerIndex, adding: literalLength, cap: cap)
        try copyLiterals(count: literalLength, source: &source, destination: &destination)
    }

    @inline(__always)
    private static func decodeMatchSection(token: UInt8, source: inout ByteBuffer, destination: inout ByteBuffer, cap: Int) throws {
        let offset = try readMatchOffset(source: &source)
        let matchLength = try readVariableLength(initial: Int(token & 0x0F), source: &source) + 4
        try ensureCapAvailable(written: destination.writerIndex, adding: matchLength, cap: cap)
        try copyMatch(offset: Int(offset), length: matchLength, into: &destination)
    }

    @inline(__always)
    private static func readMatchOffset(source: inout ByteBuffer) throws -> UInt16 {
        guard let offset = source.readInteger(endianness: .little, as: UInt16.self) else {
            throw ClickHouseError.lz4MalformedBlock("missing match offset")
        }
        guard offset > 0 else {
            throw ClickHouseError.lz4MalformedBlock("zero match offset")
        }
        return offset
    }

    @inline(__always)
    private static func ensureCapAvailable(written: Int, adding: Int, cap: Int) throws {
        let (sum, overflow) = written.addingReportingOverflow(adding)
        if capWouldBeExceeded(overflow: overflow, sum: sum, cap: cap) {
            throw ClickHouseError.lz4DecompressedSizeMismatch(
                expected: cap,
                actual: overflow ? Int.max : sum
            )
        }
    }

    @inline(__always)
    private static func capWouldBeExceeded(overflow: Bool, sum: Int, cap: Int) -> Bool {
        overflow || sum > cap
    }

    @inline(__always)
    private static func readVariableLength(initial: Int, source: inout ByteBuffer) throws -> Int {
        if initial < 15 { return initial }
        return try readVariableLengthTail(start: initial, source: &source)
    }

    private static func readVariableLengthTail(start: Int, source: inout ByteBuffer) throws -> Int {
        var length = start
        while true {
            let byte = try readVariableLengthByte(source: &source)
            length += Int(byte)
            if byte != 255 {
                return length
            }
        }
    }

    @inline(__always)
    private static func readVariableLengthByte(source: inout ByteBuffer) throws -> UInt8 {
        guard let byte = source.readInteger(as: UInt8.self) else {
            throw ClickHouseError.lz4MalformedBlock("truncated variable-length encoding")
        }
        return byte
    }

    private static func copyLiterals(
        count: Int,
        source: inout ByteBuffer,
        destination: inout ByteBuffer
    ) throws {
        guard count >= 0 else {
            throw ClickHouseError.lz4MalformedBlock("negative literal length")
        }
        guard let literals = source.readSlice(length: count) else {
            throw ClickHouseError.lz4MalformedBlock("truncated literal section (need \(count), have \(source.readableBytes))")
        }
        var copy = literals
        destination.writeBuffer(&copy)
    }

    private static func copyMatch(
        offset: Int,
        length: Int,
        into destination: inout ByteBuffer
    ) throws {
        guard offset <= destination.writerIndex else {
            throw ClickHouseError.lz4MalformedBlock("match offset \(offset) exceeds output position \(destination.writerIndex)")
        }
        for _ in 0..<length {
            try copyMatchByte(offset: offset, into: &destination)
        }
    }

    @inline(__always)
    private static func copyMatchByte(offset: Int, into destination: inout ByteBuffer) throws {
        guard let byte = destination.getInteger(at: destination.writerIndex - offset, as: UInt8.self) else {
            throw ClickHouseError.lz4MalformedBlock("match byte unreadable at offset")
        }
        destination.writeInteger(byte)
    }

    // LZ4 block format encoder. Greedy match-finding via a 12-bit hash
    // table over rolling 4-byte sequences. Each input position computes
    // a hash, the table holds the most recent occurrence of each hash,
    // and a candidate match is accepted iff the 4-byte sequences are
    // bytewise-equal AND the offset fits in UInt16 (max 65535).
    //
    // Three spec constraints are enforced when building sequences:
    //   1. last 5 bytes are always literals (no match may extend in)
    //   2. last match must start at least 12 bytes from end-of-block
    //   3. match length is encoded as `length - 4` (since matches
    //      shorter than 4 bytes don't pay for themselves vs literal)
    //
    // For inputs below the 12-byte safe window, no match-finding is
    // attempted; the output is a single literal-only sequence.
    static func compress(_ input: ByteBuffer) -> ByteBuffer {
        // Zero-copy access to the input bytes. Avoids materializing a
        // `[UInt8]` copy of the source for large blocks, halving peak
        // memory pressure on big inserts.
        input.withUnsafeReadableBytes { rawBuffer -> ByteBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let n = bytes.count
            var output = ByteBuffer()
            output.reserveCapacity(maxCompressedSize(uncompressedSize: n))

            guard n >= compressionFloor else {
                emitLiterals(bytes, range: 0..<n, into: &output)
                return output
            }

            var hashTable = [Int32](repeating: -1, count: hashTableSize)
            var anchor = 0
            var i = 0
            let limit = n - compressionFloor

            while i < limit {
                switch findMatch(in: bytes, at: i, hashTable: &hashTable) {
                case .found(let offset, let length):
                    emitSequence(
                        literals: bytes,
                        literalRange: anchor..<i,
                        matchOffset: offset,
                        matchLength: length,
                        into: &output
                    )
                    i += length
                    anchor = i
                case .notFound:
                    i += 1
                }
            }

            emitLiterals(bytes, range: anchor..<n, into: &output)
            return output
        }
    }

    static func maxCompressedSize(uncompressedSize n: Int) -> Int {
        n + (n / 255) + 16
    }

    private static let hashTableSize = 4096
    private static let hashShift = 20
    private static let hashMask = hashTableSize - 1
    private static let minMatchLength = 4
    private static let maxMatchOffset = 65_535
    private static let lastLiteralsRequired = 5
    private static let compressionFloor = 12

    private enum LZ4MatchOutcome {

        case found(offset: Int, length: Int)
        case notFound

    }

    private enum LZ4HashCandidate {

        case present(Int)
        case absent

    }

    private static func findMatch(
        in bytes: UnsafeBufferPointer<UInt8>,
        at i: Int,
        hashTable: inout [Int32]
    ) -> LZ4MatchOutcome {
        switch recordHashCandidate(bytes: bytes, at: i, hashTable: &hashTable) {
        case .absent: return .notFound
        case .present(let candidate):
            return findMatchFromCandidate(in: bytes, at: i, candidate: candidate)
        }
    }

    @inline(__always)
    private static func findMatchFromCandidate(in bytes: UnsafeBufferPointer<UInt8>, at i: Int, candidate: Int) -> LZ4MatchOutcome {
        let offset = i - candidate
        guard offsetIsAcceptable(offset) else { return .notFound }
        guard matches4(bytes, candidate, i) else { return .notFound }
        let matchLen = extendMatch(bytes: bytes, candidate: candidate, i: i)
        return .found(offset: offset, length: matchLen)
    }

    @inline(__always)
    private static func recordHashCandidate(bytes: UnsafeBufferPointer<UInt8>, at i: Int, hashTable: inout [Int32]) -> LZ4HashCandidate {
        let hash = hashFn(bytes, at: i)
        let candidate = Int(hashTable[hash])
        hashTable[hash] = Int32(i)
        return candidate >= 0 ? .present(candidate) : .absent
    }

    @inline(__always)
    private static func offsetIsAcceptable(_ offset: Int) -> Bool {
        offset > 0 && offset <= maxMatchOffset
    }

    @inline(__always)
    private static func extendMatch(bytes: UnsafeBufferPointer<UInt8>, candidate: Int, i: Int) -> Int {
        let n = bytes.count
        var matchLen = minMatchLength
        while i + matchLen < n - lastLiteralsRequired,
              bytes[candidate + matchLen] == bytes[i + matchLen] {
            matchLen += 1
        }
        return matchLen
    }

    @inline(__always)
    private static func hashFn(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> Int {
        let v = UInt32(bytes[i])
            | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16)
            | (UInt32(bytes[i + 3]) << 24)
        return Int((v &* 2_654_435_761) >> hashShift) & hashMask
    }

    @inline(__always)
    private static func matches4(_ bytes: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int) -> Bool {
        bytes12Equal(bytes, a, b) && bytes34Equal(bytes, a, b)
    }

    @inline(__always)
    private static func bytes12Equal(_ bytes: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int) -> Bool {
        bytes[a] == bytes[b] && bytes[a + 1] == bytes[b + 1]
    }

    @inline(__always)
    private static func bytes34Equal(_ bytes: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int) -> Bool {
        bytes[a + 2] == bytes[b + 2] && bytes[a + 3] == bytes[b + 3]
    }

    private static func emitLiterals(
        _ literals: UnsafeBufferPointer<UInt8>,
        range: Range<Int>,
        into output: inout ByteBuffer
    ) {
        let count = range.count
        let token: UInt8 = UInt8(min(15, count)) << 4
        output.writeInteger(token)
        if count >= 15 {
            writeVariableLength(count - 15, into: &output)
        }
        if count > 0, let base = literals.baseAddress {
            output.writeBytes(UnsafeBufferPointer(start: base + range.lowerBound, count: count))
        }
    }

    private static func emitSequence(
        literals: UnsafeBufferPointer<UInt8>,
        literalRange: Range<Int>,
        matchOffset: Int,
        matchLength: Int,
        into output: inout ByteBuffer
    ) {
        let literalCount = literalRange.count
        let matchEncoded = matchLength - minMatchLength
        let token = UInt8(min(15, literalCount)) << 4 | UInt8(min(15, matchEncoded))
        output.writeInteger(token)
        emitLiteralsSection(literals: literals, range: literalRange, count: literalCount, into: &output)
        output.writeInteger(UInt16(matchOffset), endianness: .little)
        if matchEncoded >= 15 {
            writeVariableLength(matchEncoded - 15, into: &output)
        }
    }

    @inline(__always)
    private static func emitLiteralsSection(literals: UnsafeBufferPointer<UInt8>, range: Range<Int>, count: Int, into output: inout ByteBuffer) {
        if count >= 15 {
            writeVariableLength(count - 15, into: &output)
        }
        if count > 0, let base = literals.baseAddress {
            output.writeBytes(UnsafeBufferPointer(start: base + range.lowerBound, count: count))
        }
    }

    private static func writeVariableLength(_ value: Int, into output: inout ByteBuffer) {
        var remaining = value
        while remaining >= 255 {
            output.writeInteger(UInt8(255))
            remaining -= 255
        }
        output.writeInteger(UInt8(remaining))
    }

}
