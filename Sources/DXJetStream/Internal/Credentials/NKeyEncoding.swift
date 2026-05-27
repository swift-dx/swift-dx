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

enum NKeyEncoding {

    static let prefixByteCount = 2
    static let seedByteCount = 32
    static let checksumByteCount = 2
    static let payloadByteCount = prefixByteCount + seedByteCount
    static let totalByteCount = payloadByteCount + checksumByteCount

    static let prefixByte0Index = 0
    static let prefixByte1Index = 1
    static let seedStartIndex = prefixByteCount
    static let seedEndIndex = payloadByteCount
    static let checksumLowByteIndex = payloadByteCount
    static let checksumHighByteIndex = payloadByteCount + 1

    static let seedPrefixMask: UInt8 = 0xF8
    static let subjectPrefixHighMask: UInt8 = 0x07
    static let subjectPrefixHighShift = 5

    static let subjectPrefixLowMask: UInt8 = 0x1F
    static let subjectPrefixLowShift = 3

    static let checksumByteShift = 8
}
