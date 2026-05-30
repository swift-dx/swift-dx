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

// 256-bit unsigned integer represented as 4 × UInt64 limbs in little-
// endian order. `limb0` is the least significant 64 bits, `limb3` the
// most significant. Same wire layout as `ClickHouseInt256`; the type
// distinction signals the semantic interpretation.
public struct ClickHouseUInt256: Sendable, Equatable, Hashable {

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

    public init(_ value: UInt64) {
        self.limb0 = value
        self.limb1 = 0
        self.limb2 = 0
        self.limb3 = 0
    }

    public static let zero = Self(limb0: 0, limb1: 0, limb2: 0, limb3: 0)

    public static let max = Self(
        limb0: UInt64.max,
        limb1: UInt64.max,
        limb2: UInt64.max,
        limb3: UInt64.max
    )

}
