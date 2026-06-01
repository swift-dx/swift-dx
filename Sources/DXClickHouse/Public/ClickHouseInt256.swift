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

// A value destined for a ClickHouse Int256 column: a signed 256-bit
// integer held as four little-endian UInt64 limbs, limb0 least
// significant. The wire form is the four limbs in order, each
// little-endian (32 bytes total).
public struct ClickHouseInt256: Sendable, Hashable, Codable {

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
        let extension64: UInt64 = value < 0 ? .max : 0
        self.init(limb0: UInt64(bitPattern: value), limb1: extension64, limb2: extension64, limb3: extension64)
    }
}
