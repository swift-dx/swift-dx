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

// Owner of the arena's raw byte allocation. Kept as a separate final
// class so the `ClickHouseArena` struct can retain a reference to the
// allocation and free it on deinit while the arena itself remains a
// value type.
public final class ClickHouseStorage {

    @usableFromInline
    var base: UnsafeMutablePointer<UInt8>

    @usableFromInline
    var capacity: Int

    public init(initialCapacity: Int) {
        self.capacity = initialCapacity
        self.base = UnsafeMutablePointer<UInt8>.allocate(capacity: initialCapacity)
        self.base.initialize(repeating: 0, count: initialCapacity)
    }

    deinit {
        base.deinitialize(count: capacity)
        base.deallocate()
    }

    @inlinable
    public func grow(toAtLeast minimum: Int) {
        var newSize = max(capacity * 2, 64 * 1024)
        while newSize < minimum { newSize *= 2 }
        let replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: newSize)
        replacement.initialize(repeating: 0, count: newSize)
        replacement.update(from: base, count: capacity)
        base.deinitialize(count: capacity)
        base.deallocate()
        base = replacement
        capacity = newSize
    }
}
