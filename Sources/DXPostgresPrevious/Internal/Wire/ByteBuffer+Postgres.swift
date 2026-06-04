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

import NIOCore

extension ByteBuffer {

    // PostgreSQL strings on the wire are NUL-terminated C strings.
    mutating func writeCString(_ string: String) {
        writeString(string)
        writeInteger(UInt8(0))
    }

    // Every tagged frontend message is a 1-byte type tag, a 4-byte big-endian
    // length that counts the length field plus the body but not the tag, then the
    // body. The length is only known after the body is written, so callers stamp
    // a zero placeholder here, write the body, then call backpatchLength with the
    // returned index. Returns the offset of the length field.
    mutating func writeMessageLengthPrefix(tag: UInt8) -> Int {
        writeInteger(tag)
        let lengthIndex = writerIndex
        writeInteger(Int32(0))
        return lengthIndex
    }

    mutating func backpatchLength(at lengthIndex: Int) {
        let length = Int32(writerIndex - lengthIndex)
        setInteger(length, at: lengthIndex)
    }
}
