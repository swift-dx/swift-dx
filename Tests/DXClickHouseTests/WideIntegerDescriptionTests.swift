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

// The wide-integer column types mirrored ClickHouseDecimal's old gap: a
// caller who SELECTed an Int256 / UInt256 column received four raw limbs
// with no way to read the number, and the Int128 / UInt128 wrappers printed
// their reflected form rather than the value. Each must render its exact
// decimal string, lossless across the full 256-bit range, with the signed
// types carrying a single leading minus.
@Suite("the wide-integer types render their exact decimal value")
struct WideIntegerDescriptionTests {

    @Test("UInt256 renders small, high-limb, and maximum values")
    func unsignedWide() {
        #expect(ClickHouseUInt256(5).description == "5")
        #expect(ClickHouseUInt256(0).description == "0")
        #expect(ClickHouseUInt256(limb0: 0, limb1: 1, limb2: 0, limb3: 0).description == "18446744073709551616")
        let maximum = ClickHouseUInt256(limb0: .max, limb1: .max, limb2: .max, limb3: .max)
        #expect(maximum.description == "115792089237316195423570985008687907853269984665640564039457584007913129639935")
    }

    @Test("Int256 renders positives, negatives, and the most-negative value")
    func signedWide() {
        #expect(ClickHouseInt256(255).description == "255")
        #expect(ClickHouseInt256(-1).description == "-1")
        #expect(ClickHouseInt256(-12_345).description == "-12345")
        let mostNegative = ClickHouseInt256(limb0: 0, limb1: 0, limb2: 0, limb3: 0x8000_0000_0000_0000)
        #expect(mostNegative.description == "-57896044618658097711785492504343953926634992332820282019728792003956564819968")
    }

    @Test("UInt128 forwards to the exact unsigned value")
    func unsigned128() {
        #expect(ClickHouseUInt128(123).description == "123")
        #expect(ClickHouseUInt128(UInt128.max).description == "340282366920938463463374607431768211455")
    }

    @Test("Int128 forwards to the exact signed value")
    func signed128() {
        #expect(ClickHouseInt128(-123).description == "-123")
        #expect(ClickHouseInt128(Int128.min).description == "-170141183460469231731687303715884105728")
    }
}
