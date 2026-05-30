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

// Reference-counted owner of a single block's String-column UTF-8
// payload arena. Every `ClickHouseStringView` produced from this
// column holds a strong reference to one of these handles; the bytes
// stay allocated until the last view is released.
//
// The arena is logically immutable after construction: the wire
// decoder writes the column body into a fresh `[UInt8]` exactly
// once and hands it to this owner, which then exposes the bytes
// only through `withUnsafeBytes`. The closure receives a pointer
// valid for the duration of the call; the handle's reference
// guarantees the underlying buffer is not deallocated while the
// closure runs.
//
// Sendable: the stored `[UInt8]` is a value type with `Sendable`
// conformance, the class itself never mutates after init, and the
// only externally observable state is the pointer handed to
// `withUnsafeBytes`. Concurrent reads from multiple tasks are safe
// because Swift's `Array` is copy-on-write and the array is never
// mutated through this reference.
public final class ClickHouseStringArena: @unchecked Sendable {

    @usableFromInline
    let bytes: [UInt8]

    @inlinable
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    @inlinable
    public var count: Int { bytes.count }

    // Borrow a slice of the arena's UTF-8 bytes for the duration of
    // `body`. The buffer pointer is valid only inside the closure
    // and must not be allowed to escape. The handle's reference
    // count keeps the underlying storage alive for the whole call.
    //
    // `byteOffset + byteCount` must be within bounds; the wire
    // decoder enforces this before constructing the view.
    @inlinable
    public func withSlice<Result>(
        byteOffset: Int,
        byteCount: Int,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        try bytes.withUnsafeBufferPointer { buffer in
            try Self.dispatchSlice(buffer: buffer, byteOffset: byteOffset, byteCount: byteCount, body: body)
        }
    }

    @inlinable
    static func dispatchSlice<Result>(
        buffer: UnsafeBufferPointer<UInt8>,
        byteOffset: Int,
        byteCount: Int,
        body: (UnsafeBufferPointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        guard let base = buffer.baseAddress, byteCount > 0 else {
            let empty = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
            return try body(empty)
        }
        let slice = UnsafeBufferPointer(start: base.advanced(by: byteOffset), count: byteCount)
        return try body(slice)
    }

}
