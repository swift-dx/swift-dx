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

package enum JSONString: Sendable {

    case materialized(String)
    case slice(source: [UInt8], offset: Int, length: Int)

    package init(_ string: String) {
        self = .materialized(string)
    }

    package var value: String {
        switch self {
        case .materialized(let string): string
        case .slice(let source, let offset, let length): String(decoding: source[offset ..< offset + length], as: UTF8.self)
        }
    }

    package var scalarCount: Int {
        withContiguousBytes(countCodePoints)
    }

    package func equalsString(_ other: String) -> Bool {
        var target = other
        return withContiguousBytes { mine in
            target.withUTF8 { theirs in mine.elementsEqual(theirs) }
        }
    }

    func withContiguousBytes<Output>(_ body: (UnsafeBufferPointer<UInt8>) -> Output) -> Output {
        switch self {
        case .materialized(var string):
            return string.withUTF8 { body($0) }
        case .slice(let source, let offset, let length):
            return source.withUnsafeBufferPointer { buffer in
                body(UnsafeBufferPointer(rebasing: buffer[offset ..< offset + length]))
            }
        }
    }

    private func countCodePoints(_ buffer: UnsafeBufferPointer<UInt8>) -> Int {
        var count = 0
        for byte in buffer where byte & 0xc0 != 0x80 {
            count += 1
        }
        return count
    }
}

extension JSONString: ExpressibleByStringLiteral {

    package init(stringLiteral value: String) {
        self = .materialized(value)
    }
}

extension JSONString: Equatable {

    package static func == (lhs: JSONString, rhs: JSONString) -> Bool {
        lhs.withContiguousBytes { left in
            rhs.withContiguousBytes { right in
                left.elementsEqual(right)
            }
        }
    }
}

extension JSONString: Hashable {

    package func hash(into hasher: inout Hasher) {
        withContiguousBytes { buffer in
            hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
        }
    }
}
