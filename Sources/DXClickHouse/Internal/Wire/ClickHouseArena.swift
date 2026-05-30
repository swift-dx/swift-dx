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

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Single growing byte arena that backs every recv() call for the
// lifetime of a connection. `head` is the byte the parser is about to
// read; `tail` is one past the last byte recv() wrote. After every
// packet is parsed the consumer calls compact() to slide unread bytes
// to the front so the arena does not grow without bound.
//
// Storage is held in a manually-allocated `UnsafeMutablePointer<UInt8>`
// rather than `Array<UInt8>`. The `Array` representation forced every
// `withUnsafeMutableBufferPointer` and `withUnsafeBufferPointer` call
// through Swift's noEscape exclusivity tracking (~42% of cycles on
// drain workloads, observed via perf on `swift_beginAccess`). With a
// raw pointer each access is a plain pointer load.
//
// Ownership lives in `ClickHouseStorage`, a small final class that
// owns the allocation and frees it on deinit. The arena itself is a
// struct that holds a reference to the storage owner plus head/tail
// indices, so the wider call graph keeps its existing value-semantic
// shape (the Connection holds `var arena: ClickHouseArena`).
public struct ClickHouseArena {

    @usableFromInline
    let owner: ClickHouseStorage

    @usableFromInline
    var head: Int = 0

    @usableFromInline
    var tail: Int = 0

    // 1 MiB initial arena. The recv() loop hands the kernel a buffer of
    // (capacity - tail) and the kernel returns up to that many bytes from
    // the TCP socket's receive queue in a single copy. With a 64K initial
    // capacity, a 240 MB drain costs ~3700 recv() syscalls; bumping the
    // arena to 1 MiB drops that to ~240 syscalls. The arena only grows;
    // it does not shrink, so this is one-time work per connection.
    public init(initialCapacity: Int = 1024 * 1024) {
        self.owner = ClickHouseStorage(initialCapacity: initialCapacity)
    }

    @inlinable
    public var readable: Int { tail - head }

    @inlinable
    public mutating func compact() {
        guard head > 0 else { return }
        if head == tail {
            head = 0
            tail = 0
            return
        }
        let remaining = tail - head
        let base = owner.base
        base.update(from: base + head, count: remaining)
        head = 0
        tail = remaining
    }

    @inlinable
    public mutating func ensureFreeCapacity(_ bytes: Int) {
        let free = owner.capacity - tail
        if free >= bytes { return }
        compact()
        let newFree = owner.capacity - tail
        if newFree >= bytes { return }
        let needed = tail + bytes
        owner.grow(toAtLeast: needed)
    }

    @inlinable
    public mutating func withWritePointer<R>(_ body: (UnsafeMutablePointer<UInt8>, Int) throws -> R) rethrows -> R {
        let base = owner.base
        return try body(base + tail, owner.capacity - tail)
    }

    @inlinable
    public mutating func advanceTail(by bytes: Int) {
        tail += bytes
    }

    @inlinable
    public func withReadPointer<R>(_ body: (UnsafePointer<UInt8>, Int) throws -> R) rethrows -> R {
        let base = owner.base
        return try body(UnsafePointer(base + head), tail - head)
    }

    @inlinable
    public mutating func advanceHead(by bytes: Int) {
        head += bytes
    }
}
