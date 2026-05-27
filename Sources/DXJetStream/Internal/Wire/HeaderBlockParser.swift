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

enum HeaderBlockParser {

    static func parse(_ bytes: [UInt8]) -> [NatsHeader] {
        bytes.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return [] }
            return parsePointer(base, length: pointer.count)
        }
    }

    static func parse(view: ByteBufferView, from start: Int, length: Int) -> [NatsHeader] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        bytes.append(contentsOf: view[start..<(start + length)])
        return parse(bytes)
    }

    private static func parsePointer(_ base: UnsafePointer<UInt8>, length: Int) -> [NatsHeader] {
        var headers: [NatsHeader] = []
        var index = skipFirstLine(base, length: length)
        while index < length {
            switch parseOneHeader(base, length: length, from: index) {
            case .done: return headers
            case .header(let header, let next):
                headers.append(header)
                index = next
            }
        }
        return headers
    }

    private enum ParseStep {

        case done
        case header(NatsHeader, nextIndex: Int)
    }

    private static func skipFirstLine(_ base: UnsafePointer<UInt8>, length: Int) -> Int {
        let crlfIndex = scanToCrlf(base, length: length, from: 0)
        return min(crlfIndex + 2, length)
    }

    private static func parseOneHeader(_ base: UnsafePointer<UInt8>, length: Int, from start: Int) -> ParseStep {
        if isCrlf(base, length: length, at: start) { return .done }
        let colonIndex = scanTo(base, length: length, byte: Ascii.colon, from: start)
        guard colonIndex < length else { return .done }
        let name = String(decoding: UnsafeBufferPointer(start: base.advanced(by: start), count: colonIndex - start), as: UTF8.self)
        let valueStart = skipLeadingSpace(base, length: length, from: colonIndex + 1)
        let valueEnd = scanToCrlf(base, length: length, from: valueStart)
        let value = String(decoding: UnsafeBufferPointer(start: base.advanced(by: valueStart), count: valueEnd - valueStart), as: UTF8.self)
        return .header(NatsHeader(name: name, value: value), nextIndex: min(valueEnd + 2, length))
    }

    @inline(__always)
    private static func isCrlf(_ base: UnsafePointer<UInt8>, length: Int, at index: Int) -> Bool {
        index + 1 < length && base[index] == Ascii.carriageReturn && base[index + 1] == Ascii.lineFeed
    }

    @inline(__always)
    private static func skipLeadingSpace(_ base: UnsafePointer<UInt8>, length: Int, from start: Int) -> Int {
        var index = start
        while index < length && base[index] == Ascii.space {
            index += 1
        }
        return index
    }

    @inline(__always)
    private static func scanTo(_ base: UnsafePointer<UInt8>, length: Int, byte: UInt8, from start: Int) -> Int {
        var index = start
        while index < length && base[index] != byte {
            index += 1
        }
        return index
    }

    @inline(__always)
    private static func scanToCrlf(_ base: UnsafePointer<UInt8>, length: Int, from start: Int) -> Int {
        var index = start
        while index + 1 < length {
            if isCrlf(base, length: length, at: index) { return index }
            index += 1
        }
        return length
    }
}
