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

// Borrowed view over one `FixedString(N)` row in a SELECT block. The
// row's bytes live at a known offset in the column's contiguous byte
// arena; reads are pointer arithmetic, no varint scan, no copy.
//
// Lifetime is rooted at the arena handle, which is a Sendable
// reference type held by the column. As long as any view exists, the
// arena bytes stay alive; once the last view, column, or block holding
// the arena is released, the bytes are freed. This is the
// Swift-without-`~Escapable` analogue of clickhouse-cpp's
// `ColumnFixedString::At(row)` returning a `std::string_view`.
//
// Compared with `ClickHouseStringView`, this view is significantly
// cheaper: the row width is known at column-decode time, so there is
// no offsets array to index into and no per-row scan to recover the
// payload length. Hot event-sourced ledger workloads (point lookup by
// `FixedString(44)` entity_id, `has` over `Array(FixedString(44))`
// references, kind-equality slices) read these views directly without
// ever materialising a Swift `String`.
public struct ClickHouseFixedStringView: Sendable {

    @usableFromInline
    let arena: ClickHouseFixedStringArena
    @usableFromInline
    let rowIndex: Int

    @inlinable
    public var fixedWidth: Int { arena.fixedWidth }

    @inlinable
    public var byteCount: Int { arena.fixedWidth }

    @inlinable
    init(arena: ClickHouseFixedStringArena, rowIndex: Int) {
        self.arena = arena
        self.rowIndex = rowIndex
    }

    // Borrow the row's `fixedWidth` bytes for the duration of `body`.
    // The buffer pointer is valid only while `body` is executing; do
    // not let it escape. The arena reference held by `self`
    // guarantees the memory remains live for the whole call.
    @inlinable
    public func withBytes<Result>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        try arena.withRow(at: rowIndex, body)
    }

    // Materialise the row into an owning Swift String. Allocates one
    // heap String + memcpy of the payload. Use when the caller intends
    // to keep the row past the lifetime of the block.
    public func asString() -> String {
        if arena.fixedWidth == 0 { return "" }
        return withBytes { buffer in
            String(decoding: buffer, as: Unicode.UTF8.self)
        }
    }

    // Byte-for-byte equality against another view. Skips String
    // materialisation entirely.
    public static func == (lhs: ClickHouseFixedStringView, rhs: ClickHouseFixedStringView) -> Bool {
        switch Self.classifyPair(lhs, rhs) {
        case .widthMismatch: return false
        case .sameArenaSameRow: return true
        case .comparable:
            return lhs.withBytes { left in
                rhs.withBytes { right in
                    Self.bytesEqualSameLength(left, right)
                }
            }
        }
    }

    @usableFromInline
    enum PairClassification: Sendable {

        case widthMismatch
        case sameArenaSameRow
        case comparable

    }

    @inlinable
    static func classifyPair(_ lhs: ClickHouseFixedStringView, _ rhs: ClickHouseFixedStringView) -> PairClassification {
        if lhs.arena.fixedWidth != rhs.arena.fixedWidth { return .widthMismatch }
        if lhs.arena === rhs.arena, lhs.rowIndex == rhs.rowIndex { return .sameArenaSameRow }
        return .comparable
    }

    // UTF-8 byte equality against a Swift String literal or owned
    // String. Skips materialising the view into a String.
    public static func == (lhs: ClickHouseFixedStringView, rhs: String) -> Bool {
        lhs.equalsString(rhs)
    }

    public static func == (lhs: String, rhs: ClickHouseFixedStringView) -> Bool {
        rhs.equalsString(lhs)
    }

    @inlinable
    func equalsString(_ string: String) -> Bool {
        let utf8Count = string.utf8.count
        if utf8Count != arena.fixedWidth { return false }
        if utf8Count == 0 { return true }
        return withBytes { viewBuffer in
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

extension ClickHouseFixedStringView: Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(arena.fixedWidth)
        if arena.fixedWidth == 0 { return }
        withBytes { buffer in
            for byteIndex in 0..<buffer.count {
                hasher.combine(buffer[byteIndex])
            }
        }
    }

}

extension ClickHouseFixedStringView: CustomStringConvertible {

    public var description: String { asString() }

}
