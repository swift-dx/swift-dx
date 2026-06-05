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
import Foundation
import Testing

// A FixedString(N) slot is always N bytes on the wire: a value shorter than N
// is zero-padded. `bytes` is documented as the full padded slot, so a value
// constructed from a short string or short byte array must normalise to N
// bytes — otherwise it compares unequal to the very same value read back from
// a result column (which always carries the full N-byte slot), and a caller's
// constructed expectation silently never matches a decoded row.
@Suite("FixedString constructors pad to the full slot width")
struct FixedStringPaddingTests {

    @Test("a short string and short byte array pad to the slot width")
    func shortValuesPadToWidth() {
        let wireForm = ClickHouseFixedString(bytes: [0x61, 0x62, 0x00, 0x00], length: 4)

        let fromString = ClickHouseFixedString("ab", length: 4)
        let fromShortBytes = ClickHouseFixedString(bytes: [0x61, 0x62], length: 4)

        #expect(fromString.bytes.count == 4)
        #expect(fromShortBytes.bytes.count == 4)
        #expect(fromString == wireForm)
        #expect(fromShortBytes == wireForm)
        #expect(fromString.text == "ab")
    }

    @Test("an exact-width value is unchanged")
    func exactWidthUnchanged() {
        let exact = ClickHouseFixedString("abcd", length: 4)
        #expect(exact.bytes == [0x61, 0x62, 0x63, 0x64])
        #expect(exact.text == "abcd")
    }
}
