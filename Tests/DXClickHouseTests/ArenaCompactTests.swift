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

import DXClickHouse
import Testing

// compact() slides the unread region [head, tail) down to the front of the
// arena after each packet is parsed. On a large drain the source and
// destination overlap (tail > 2*head), so the slide must be overlap-safe -
// every unread byte has to survive in order. This is the buffer-management
// core that every recv() path depends on; it had no direct test.
@Suite("ClickHouseArena.compact slides unread bytes overlap-safely")
struct ArenaCompactTests {

    @Test("a large unread region with a tiny head keeps every byte in order")
    func compactLargeOverlap() {
        let total = 1 << 20
        var arena = ClickHouseArena(initialCapacity: total)
        arena.withWritePointer { pointer, _ in
            for index in 0..<total { pointer[index] = UInt8(truncatingIfNeeded: index) }
        }
        arena.advanceTail(by: total)
        arena.advanceHead(by: 3)
        arena.compact()

        #expect(arena.readable == total - 3)
        var firstMismatch = -1
        arena.withReadPointer { pointer, count in
            for index in 0..<count where pointer[index] != UInt8(truncatingIfNeeded: index + 3) {
                firstMismatch = index
                break
            }
        }
        #expect(firstMismatch == -1)
    }

    @Test("a fully-consumed arena resets to empty")
    func compactWhenFullyConsumed() {
        var arena = ClickHouseArena(initialCapacity: 4096)
        arena.advanceTail(by: 100)
        arena.advanceHead(by: 100)
        arena.compact()
        #expect(arena.readable == 0)
    }

    @Test("a small overlapping slide preserves the unread bytes")
    func compactSmallOverlap() {
        var arena = ClickHouseArena(initialCapacity: 4096)
        let total = 64
        arena.withWritePointer { pointer, _ in
            for index in 0..<total { pointer[index] = UInt8(truncatingIfNeeded: index * 7 + 1) }
        }
        arena.advanceTail(by: total)
        arena.advanceHead(by: 5)
        arena.compact()

        #expect(arena.readable == total - 5)
        var firstMismatch = -1
        arena.withReadPointer { pointer, count in
            for index in 0..<count where pointer[index] != UInt8(truncatingIfNeeded: (index + 5) * 7 + 1) {
                firstMismatch = index
                break
            }
        }
        #expect(firstMismatch == -1)
    }
}
