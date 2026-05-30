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

// Deterministic RNG for property tests. The state is a `UInt64` so the
// seed is the entire reproducer: a failing test can be re-run by
// re-using the same seed, and the payload is byte-identical across
// machines and runs.
//
// The advance step is the splitmix64 mixer (Stafford's variant): one
// add of an odd constant, then xor-shift mixing. It has a full 2^64
// period and good enough statistical properties for fuzz coverage; we
// are not generating crypto, only varied test inputs.
struct SeededRandomNumberGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        // The mixer behaves poorly when state == 0, so fold the seed
        // through the same step once to derive the initial state.
        var s = seed &+ 0x9E37_79B9_7F4A_7C15
        s = (s ^ (s >> 30)) &* 0xBF58_476D_1CE4_E5B9
        s = (s ^ (s >> 27)) &* 0x94D0_49BB_1331_11EB
        s = s ^ (s >> 31)
        self.state = s
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

}
