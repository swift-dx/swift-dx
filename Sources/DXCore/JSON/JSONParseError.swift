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

package enum JSONParseError: Error, Sendable, Equatable {

    case emptyInput
    case unexpectedEndOfInput(byteOffset: Int)
    case unexpectedByte(byteOffset: Int, found: UInt8)
    case invalidLiteral(byteOffset: Int)
    case invalidNumber(byteOffset: Int)
    case invalidStringEscape(byteOffset: Int)
    case invalidUnicodeEscape(byteOffset: Int)
    case unpairedSurrogate(byteOffset: Int)
    case invalidUTF8(byteOffset: Int)
    case controlCharacterInString(byteOffset: Int)
    case depthLimitExceeded(byteOffset: Int, limit: Int)
    case documentTooLarge(byteLength: Int, limit: Int)
    case duplicateKey(byteOffset: Int, key: String)
    case trailingData(byteOffset: Int)
}

extension JSONParseError: CustomStringConvertible {

    package var description: String {
        switch self {
        case .emptyInput: "input is empty"
        case .unexpectedEndOfInput(let offset): "unexpected end of input at byte \(offset)"
        case .unexpectedByte(let offset, let found): "unexpected byte 0x\(byteHex(found)) at byte \(offset)"
        case .invalidLiteral(let offset): "invalid literal at byte \(offset) (expected true, false, or null)"
        case .invalidNumber(let offset): "invalid number token at byte \(offset)"
        case .invalidStringEscape(let offset): "invalid escape sequence in string at byte \(offset)"
        case .invalidUnicodeEscape(let offset): "invalid \\u escape in string at byte \(offset)"
        case .unpairedSurrogate(let offset): "unpaired UTF-16 surrogate in string at byte \(offset)"
        case .invalidUTF8(let offset): "invalid UTF-8 byte sequence in string at byte \(offset)"
        case .controlCharacterInString(let offset): "unescaped control character in string at byte \(offset)"
        case .depthLimitExceeded(let offset, let limit): "nesting depth exceeded limit \(limit) at byte \(offset)"
        case .documentTooLarge(let length, let limit): "document length \(length) exceeds limit \(limit)"
        case .duplicateKey(let offset, let key): "duplicate object key '\(key)' at byte \(offset)"
        case .trailingData(let offset): "unexpected trailing data after value at byte \(offset)"
        }
    }

    private func byteHex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let high = digits[Int(byte >> 4)]
        let low = digits[Int(byte & 0x0f)]
        return String(decoding: [high, low], as: UTF8.self)
    }
}
