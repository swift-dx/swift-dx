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

enum FormatNetwork {

    static func isIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return everyOctetValid(parts)
    }

    static func everyOctetValid(_ parts: [Substring]) -> Bool {
        for part in parts where !octetValid(part) {
            return false
        }
        return true
    }

    static func octetValid(_ part: Substring) -> Bool {
        let bytes = Array(part.utf8)
        guard bytes.count >= 1, bytes.count <= 3 else { return false }
        return FormatScan.numberInRange(bytes[...], low: 0, high: 255)
    }

    static func isIPv6(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count >= 2, bytes.count <= 45 else { return false }
        return ipv6CharsValid(bytes)
    }

    static func ipv6CharsValid(_ bytes: [UInt8]) -> Bool {
        for byte in bytes where !isIPv6Char(byte) {
            return false
        }
        return true
    }

    static func isIPv6Char(_ byte: UInt8) -> Bool {
        if FormatScan.isHex(byte) { return true }
        return byte == Ascii.colon || byte == Ascii.dot
    }

    static func isHostname(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard !bytes.isEmpty, bytes.count <= 253 else { return false }
        return hostnameCharsValid(bytes)
    }

    static func hostnameCharsValid(_ bytes: [UInt8]) -> Bool {
        for byte in bytes where !isHostnameChar(byte) {
            return false
        }
        return true
    }

    static func isHostnameChar(_ byte: UInt8) -> Bool {
        if FormatScan.isDigit(byte) { return true }
        return isLetterHyphenOrDot(byte)
    }

    static func isLetterHyphenOrDot(_ byte: UInt8) -> Bool {
        if isAsciiLetter(byte) { return true }
        return byte == Ascii.hyphen || byte == Ascii.dot
    }

    static func isAsciiLetter(_ byte: UInt8) -> Bool {
        if byte >= Ascii.lowerA, byte <= Ascii.lowerZ { return true }
        if byte >= Ascii.upperA, byte <= Ascii.upperZ { return true }
        return false
    }

    static func isEmail(_ string: String) -> Bool {
        let parts = string.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return emailPartsValid(parts)
    }

    static func emailPartsValid(_ parts: [Substring]) -> Bool {
        guard !parts[0].isEmpty else { return false }
        return domainValid(parts[1])
    }

    static func domainValid(_ domain: Substring) -> Bool {
        guard domain.contains(".") else { return false }
        return domain.last != "."
    }

    static func isURI(_ string: String) -> Bool {
        let parts = string.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return schemeValid(parts[0])
    }

    static func schemeValid(_ scheme: Substring) -> Bool {
        guard let first = scheme.first else { return false }
        return first.isLetter
    }

    static func isURIReference(_ string: String) -> Bool {
        !string.utf8.contains(Ascii.space)
    }
}
