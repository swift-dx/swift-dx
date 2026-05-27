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

package enum JSONScan {

    private enum QuoteByteOutcome {

        case escape
        case closing
        case other
    }

    private enum ExtractOutcome {

        case found(String)
        case notFound
    }

    package static func field<View>(_ view: View, start: Int, end: Int, key: [UInt8]) -> String
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        let keyCount = key.count
        guard end - start >= keyCount + 3 else { return "" }
        return scanOccurrences(view, start: start, end: end, key: key, limit: end - keyCount - 3)
    }

    private static func scanOccurrences<View>(_ view: View, start: Int, end: Int, key: [UInt8], limit: Int) -> String
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        var keyStart = start
        while keyStart <= limit {
            if case .found(let result) = tryExtractAt(view, keyStart: keyStart, key: key, end: end) {
                return result
            }
            keyStart &+= 1
        }
        return ""
    }

    @inline(__always)
    private static func tryExtractAt<View>(_ view: View, keyStart: Int, key: [UInt8], end: Int) -> ExtractOutcome
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        guard ByteScan.keyMatches(view, at: keyStart, key: key) else { return .notFound }
        let valueOpen = openValueQuote(view, after: keyStart &+ key.count, end: end)
        guard valueOpen >= 0 else { return .notFound }
        return .found(readString(view, from: valueOpen, end: end))
    }

    @inline(__always)
    private static func openValueQuote<View>(_ view: View, after position: Int, end: Int) -> Int
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        var p = ByteScan.skipSpaces(view, from: position, end: end)
        guard p < end, view[p] == Ascii.colon else { return -1 }
        p = ByteScan.skipSpaces(view, from: p &+ 1, end: end)
        guard p < end, view[p] == Ascii.quote else { return -1 }
        return p &+ 1
    }

    @inline(__always)
    private static func readString<View>(_ view: View, from valueStart: Int, end: Int) -> String
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        let closing = findClosingQuote(view, from: valueStart, end: end)
        guard closing >= 0 else { return "" }
        let bytes = (valueStart..<closing).map { view[$0] }
        return String(decoding: bytes, as: UTF8.self)
    }

    @inline(__always)
    private static func findClosingQuote<View>(_ view: View, from position: Int, end: Int) -> Int
        where View: RandomAccessCollection, View.Element == UInt8, View.Index == Int {
        var p = position
        while p < end {
            switch classifyQuoteByte(view[p]) {
            case .escape: return -1
            case .closing: return p
            case .other: p &+= 1
            }
        }
        return -1
    }

    @inline(__always)
    private static func classifyQuoteByte(_ byte: UInt8) -> QuoteByteOutcome {
        switch byte {
        case Ascii.backslash: return .escape
        case Ascii.quote: return .closing
        default: return .other
        }
    }
}
