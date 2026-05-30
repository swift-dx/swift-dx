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

import DXCore

enum JSONParseFailure {

    static func byteOffset(_ error: JSONParseError) -> Int {
        switch error {
        case .emptyInput: 0
        case .unexpectedEndOfInput(let offset): offset
        case .unexpectedByte(let offset, _): offset
        case .invalidLiteral(let offset): offset
        case .invalidNumber(let offset): offset
        case .invalidStringEscape(let offset): offset
        case .invalidUnicodeEscape(let offset): offset
        case .unpairedSurrogate(let offset): offset
        case .invalidUTF8(let offset): offset
        case .controlCharacterInString(let offset): offset
        case .depthLimitExceeded(let offset, _): offset
        case .documentTooLarge: 0
        case .duplicateKey(let offset, _): offset
        case .trailingData(let offset): offset
        }
    }

    static func hint(_ error: JSONParseError) -> String {
        error.description
    }
}
