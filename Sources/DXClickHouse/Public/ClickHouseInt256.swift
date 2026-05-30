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

// 256-bit signed integer represented as 4 × UInt64 limbs in little-
// endian order. `limb0` is the least significant 64 bits, `limb3` the
// most significant (top bit of `limb3` is the sign).
//
// Pure storage type: no arithmetic. ClickHouse Int256 columns transport
// the bytes; arithmetic happens server-side via SQL. Constructing from
// or converting to a Swift native integer type happens through bridging
// helpers (`init(_ value: Int64)`, etc.) when needed.
public struct ClickHouseInt256: Sendable, Equatable, Hashable {

    public let limb0: UInt64
    public let limb1: UInt64
    public let limb2: UInt64
    public let limb3: UInt64

    public init(limb0: UInt64, limb1: UInt64, limb2: UInt64, limb3: UInt64) {
        self.limb0 = limb0
        self.limb1 = limb1
        self.limb2 = limb2
        self.limb3 = limb3
    }

    public init(_ value: Int64) {
        // Sign-extend: negative Int64 fills the upper limbs with 0xFFFF...
        let signExtension: UInt64 = value < 0 ? UInt64.max : 0
        self.limb0 = UInt64(bitPattern: value)
        self.limb1 = signExtension
        self.limb2 = signExtension
        self.limb3 = signExtension
    }

    public static let zero = Self(limb0: 0, limb1: 0, limb2: 0, limb3: 0)

    public static let min = Self(
        limb0: 0,
        limb1: 0,
        limb2: 0,
        limb3: 0x8000_0000_0000_0000
    )

    public static let max = Self(
        limb0: UInt64.max,
        limb1: UInt64.max,
        limb2: UInt64.max,
        limb3: 0x7FFF_FFFF_FFFF_FFFF
    )

}
