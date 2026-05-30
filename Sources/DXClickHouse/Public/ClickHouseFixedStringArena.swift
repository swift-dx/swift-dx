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

// Reference-counted owner of a single block's FixedString-column byte
// arena. Wire format for `FixedString(N)` is plain `N` bytes per row
// with no varint length prefix, so the arena needs only the contiguous
// payload buffer plus the per-row width. Row `i` lives at
// `[i * fixedWidth ..< (i + 1) * fixedWidth]`.
//
// Every `ClickHouseFixedStringView` produced from this column holds a
// strong reference to one of these handles; the bytes stay allocated
// until the last view is released.
//
// Sendable: the stored `[UInt8]` is a value type with `Sendable`
// conformance, the class itself never mutates after init, and the
// only externally observable state is the pointer handed to
// `withRow`. Concurrent reads from multiple tasks are safe because
// Swift's `Array` is copy-on-write and the array is never mutated
// through this reference.
public final class ClickHouseFixedStringArena: @unchecked Sendable {

    @usableFromInline
    let bytes: [UInt8]
    public let fixedWidth: Int
    public let rowCount: Int

    @inlinable
    public init(bytes: [UInt8], fixedWidth: Int) {
        self.bytes = bytes
        self.fixedWidth = fixedWidth
        self.rowCount = fixedWidth == 0 ? 0 : bytes.count / fixedWidth
    }

    @inlinable
    public var byteCount: Int { bytes.count }

    // Borrow the fixed-width row bytes for the duration of `body`. The
    // buffer pointer is valid only inside the closure and must not be
    // allowed to escape. The handle's reference count keeps the
    // underlying storage alive for the whole call.
    //
    // `rowIndex` must be within `0..<rowCount`; the wire decoder
    // enforces this before constructing the view.
    @inlinable
    public func withRow<Result>(
        at rowIndex: Int,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        try bytes.withUnsafeBufferPointer { buffer in
            try Self.dispatchRow(buffer: buffer, rowIndex: rowIndex, fixedWidth: fixedWidth, body: body)
        }
    }

    @inlinable
    static func dispatchRow<Result>(
        buffer: UnsafeBufferPointer<UInt8>,
        rowIndex: Int,
        fixedWidth: Int,
        body: (UnsafeBufferPointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        guard let base = buffer.baseAddress, fixedWidth > 0 else {
            let empty = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
            return try body(empty)
        }
        let slice = UnsafeBufferPointer(start: base.advanced(by: rowIndex * fixedWidth), count: fixedWidth)
        return try body(slice)
    }

}
