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

// A value destined for a ClickHouse UInt256 column: an unsigned 256-bit
// integer held as four little-endian UInt64 limbs, limb0 least
// significant. The wire form is the four limbs in order, each
// little-endian (32 bytes total).
public struct ClickHouseUInt256: Sendable, Hashable, Codable {

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
        self.init(limb0: value, limb1: 0, limb2: 0, limb3: 0)
    }

    package init(littleEndianBytes bytes: [UInt8]) {
        let limbs = ClickHouseWideIntegerWire.limbs(fromLittleEndianBytes: bytes)
        self.init(limb0: limbs.0, limb1: limbs.1, limb2: limbs.2, limb3: limbs.3)
    }

    package var littleEndianBytes: [UInt8] {
        ClickHouseWideIntegerWire.littleEndianBytes(limb0: limb0, limb1: limb1, limb2: limb2, limb3: limb3)
    }
}

extension ClickHouseUInt256: CustomStringConvertible {

    public var description: String {
        ClickHouseWideDecimal.unsignedDigits((limb0, limb1, limb2, limb3))
    }
}
