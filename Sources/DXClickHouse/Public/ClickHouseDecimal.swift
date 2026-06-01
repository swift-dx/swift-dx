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

// A value destined for a ClickHouse Decimal column. The stored magnitude is
// the signed unscaled integer (the represented value is `magnitude /
// 10^scale`). The unscaled integer is held as four little-endian UInt64
// limbs, limb0 least significant, sign-extended across unused limbs. The
// wire form writes `byteWidth` little-endian bytes per row, where the width
// is selected from the declared precision: P<=9 -> 4 (Int32), P<=18 -> 8
// (Int64), P<=38 -> 16 (Int128), P<=76 -> 32 (four limbs).
public struct ClickHouseDecimal: Sendable, Hashable, Codable {

    public let limb0: UInt64
    public let limb1: UInt64
    public let limb2: UInt64
    public let limb3: UInt64
    public let precision: UInt8
    public let scale: UInt8

    public init(limb0: UInt64, limb1: UInt64, limb2: UInt64, limb3: UInt64, precision: UInt8, scale: UInt8) {
        self.limb0 = limb0
        self.limb1 = limb1
        self.limb2 = limb2
        self.limb3 = limb3
        self.precision = precision
        self.scale = scale
    }

    public init(unscaled: Int64, precision: UInt8, scale: UInt8) {
        let extension64: UInt64 = unscaled < 0 ? .max : 0
        self.init(
            limb0: UInt64(bitPattern: unscaled),
            limb1: extension64,
            limb2: extension64,
            limb3: extension64,
            precision: precision,
            scale: scale
        )
    }
}
