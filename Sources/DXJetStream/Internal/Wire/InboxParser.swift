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
import NIOCore

enum InboxParser {

    enum Result: Sendable, Equatable {

        case notMatched
        case matched(UInt64)
    }

    static func parseSuffix(_ view: ByteBufferView, start: Int, end: Int, prefixBytes: [UInt8]) -> Result {
        let length = end - start
        guard length >= 0 else { return .notMatched }
        return view.withUnsafeBytes { rawBuffer -> Result in
            parseSuffixFromRaw(rawBuffer: rawBuffer, viewStart: view.startIndex, start: start, length: length, prefixBytes: prefixBytes)
        }
    }

    @inline(__always)
    private static func parseSuffixFromRaw(rawBuffer: UnsafeRawBufferPointer, viewStart: Int, start: Int, length: Int, prefixBytes: [UInt8]) -> Result {
        guard let basePointer = rawBuffer.baseAddress else { return .notMatched }
        let typedBase = basePointer.assumingMemoryBound(to: UInt8.self)
        let offset = start - viewStart
        guard offset >= 0, offset + length <= rawBuffer.count else { return .notMatched }
        return parseSuffixFromPointer(pointer: typedBase + offset, length: length, prefixBytes: prefixBytes)
    }

    @inline(__always)
    private static func parseSuffixFromPointer(pointer: UnsafePointer<UInt8>, length: Int, prefixBytes: [UInt8]) -> Result {
        guard prefixMatches(pointer: pointer, length: length, prefixBytes: prefixBytes) else { return .notMatched }
        let suffixStart = prefixBytes.count + 1
        return decodeBase36Suffix(pointer: pointer + suffixStart, length: length - suffixStart)
    }

    @inline(__always)
    private static func prefixMatches(pointer: UnsafePointer<UInt8>, length: Int, prefixBytes: [UInt8]) -> Bool {
        let prefixLen = prefixBytes.count
        guard length >= prefixLen + 2 else { return false }
        let matches = prefixBytes.withUnsafeBufferPointer { expectedPointer -> Bool in
            guard let base = expectedPointer.baseAddress else { return false }
            return bytesEqual(pointer, base, count: prefixLen)
        }
        guard matches else { return false }
        return pointer[prefixLen] == Ascii.dot
    }

    @inline(__always)
    private static func bytesEqual(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, count: Int) -> Bool {
        for i in 0..<count {
            if a[i] != b[i] { return false }
        }
        return true
    }

    private static func decodeBase36Suffix(pointer: UnsafePointer<UInt8>, length: Int) -> Result {
        var value: UInt64 = 0
        for index in 0..<length {
            switch ByteScan.base36Digit(of: pointer[index]) {
            case .invalid: return .notMatched
            case .digit(let digit): value = value &* Radix.base36 &+ UInt64(digit)
            }
        }
        return .matched(value)
    }
}
