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

// Borrowed view over one String row in a SELECT block. Stores a
// reference to the per-block UTF-8 arena plus the byte range that
// belongs to this row, so reading the bytes never allocates and never
// copies the payload out of the wire-decoded buffer.
//
// Lifetime is rooted at the arena handle, which is a Sendable
// reference type held by the column. As long as any view exists, the
// arena bytes stay alive; once the last view, column, or block holding
// the arena is released, the bytes are freed. This is the
// Swift-without-`~Escapable` analogue of clickhouse-cpp's
// `ColumnString::At(row)` returning a `std::string_view` that borrows
// from `ColumnString::Block` — the difference is ARC ownership in
// place of explicit lifetime tracking.
//
// Use this view when the caller intends to filter, compare, hash, or
// project rows without materialising every payload into a Swift
// `String`. Each `asString()` call allocates a single `String`; each
// `==` against another view or a `String` literal walks the bytes
// directly. Rows that the consumer never inspects pay zero String
// heap-allocation cost.
public struct ClickHouseStringView: Sendable {

    @usableFromInline
    let arena: ClickHouseStringArena
    @usableFromInline
    let byteOffset: Int
    @usableFromInline
    let byteCount: Int

    @inlinable
    public var utf8Length: Int { byteCount }

    @inlinable
    public var isEmpty: Bool { byteCount == 0 }

    @inlinable
    init(arena: ClickHouseStringArena, byteOffset: Int, byteCount: Int) {
        self.arena = arena
        self.byteOffset = byteOffset
        self.byteCount = byteCount
    }

    // Borrow the UTF-8 bytes for the duration of `body`. The buffer
    // pointer is valid only while `body` is executing; do not let it
    // escape. The arena reference held by `self` guarantees the
    // memory remains live for the whole call.
    @inlinable
    public func withUTF8Bytes<Result>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        try arena.withSlice(byteOffset: byteOffset, byteCount: byteCount, body)
    }

    // Materialise the row into an owning Swift String. Allocates one
    // heap String + memcpy of the payload. Use when the caller intends
    // to keep the row past the lifetime of the block.
    public func asString() -> String {
        if byteCount == 0 { return "" }
        return withUTF8Bytes { buffer in
            String(decoding: buffer, as: Unicode.UTF8.self)
        }
    }

    // Byte-for-byte equality against another view. Skips String
    // materialisation entirely.
    public static func == (lhs: ClickHouseStringView, rhs: ClickHouseStringView) -> Bool {
        switch Self.classifyPair(lhs, rhs) {
        case .lengthMismatch: return false
        case .bothEmpty: return true
        case .sameArenaSameOffset: return true
        case .comparable:
            return lhs.withUTF8Bytes { left in
                rhs.withUTF8Bytes { right in
                    Self.bytesEqualSameLength(left, right)
                }
            }
        }
    }

    @usableFromInline
    enum PairClassification: Sendable {

        case lengthMismatch
        case bothEmpty
        case sameArenaSameOffset
        case comparable

    }

    @inlinable
    static func classifyPair(_ lhs: ClickHouseStringView, _ rhs: ClickHouseStringView) -> PairClassification {
        if lhs.byteCount != rhs.byteCount { return .lengthMismatch }
        if lhs.byteCount == 0 { return .bothEmpty }
        return classifyNonEmptyPair(lhs, rhs)
    }

    @inlinable
    static func classifyNonEmptyPair(_ lhs: ClickHouseStringView, _ rhs: ClickHouseStringView) -> PairClassification {
        if lhs.arena === rhs.arena, lhs.byteOffset == rhs.byteOffset { return .sameArenaSameOffset }
        return .comparable
    }

    // UTF-8 byte equality against a Swift String literal or owned
    // String. Skips materialising the view into a String.
    public static func == (lhs: ClickHouseStringView, rhs: String) -> Bool {
        lhs.equalsString(rhs)
    }

    public static func == (lhs: String, rhs: ClickHouseStringView) -> Bool {
        rhs.equalsString(lhs)
    }

    @inlinable
    func equalsString(_ string: String) -> Bool {
        let utf8Count = string.utf8.count
        if utf8Count != byteCount { return false }
        if byteCount == 0 { return true }
        return withUTF8Bytes { viewBuffer in
            Self.bytesEqualToUTF8View(buffer: viewBuffer, utf8: string.utf8)
        }
    }

    @inlinable
    static func bytesEqualSameLength(
        _ left: UnsafeBufferPointer<UInt8>,
        _ right: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        for byteIndex in 0..<left.count {
            if left[byteIndex] != right[byteIndex] { return false }
        }
        return true
    }

    @inlinable
    static func bytesEqualToUTF8View(buffer: UnsafeBufferPointer<UInt8>, utf8: String.UTF8View) -> Bool {
        var bufferIndex = 0
        for codeUnit in utf8 {
            if buffer[bufferIndex] != codeUnit { return false }
            bufferIndex += 1
        }
        return true
    }

}

extension ClickHouseStringView: Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(byteCount)
        if byteCount == 0 { return }
        withUTF8Bytes { buffer in
            for byteIndex in 0..<buffer.count {
                hasher.combine(buffer[byteIndex])
            }
        }
    }

}

extension ClickHouseStringView: CustomStringConvertible {

    public var description: String { asString() }

}
