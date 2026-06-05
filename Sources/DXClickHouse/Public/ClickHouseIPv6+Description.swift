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

extension ClickHouseIPv6: CustomStringConvertible {

    // RFC 5952 canonical form: lowercase hextets with no leading zeros, the
    // single longest run of two or more zero groups collapsed to "::"
    // (leftmost run on a tie), and a lone zero group left intact. The
    // IPv4-embedded notation (::ffff:a.b.c.d) is not used; every group is
    // rendered as hex.
    public var description: String {
        let groups = Self.groups(from: bytes)
        let lengths = Self.zeroRunLengths(groups)
        let runStart = Self.longestZeroRunStart(lengths)
        return lengths[runStart] >= 2
            ? Self.renderCompressed(groups, runStart: runStart, runLength: lengths[runStart])
            : Self.renderPlain(groups)
    }

    private static func groups(from bytes: [UInt8]) -> [UInt16] {
        var padded = bytes
        if padded.count < 16 {
            padded += Array(repeating: 0, count: 16 - padded.count)
        }
        var result: [UInt16] = []
        for index in 0..<8 {
            result.append(UInt16(padded[index * 2]) << 8 | UInt16(padded[index * 2 + 1]))
        }
        return result
    }

    // lengths[i] is the count of consecutive zero groups starting at i. The
    // trailing scratch slot lets the right-to-left scan read lengths[i + 1]
    // without a bounds branch.
    private static func zeroRunLengths(_ groups: [UInt16]) -> [Int] {
        var lengths = [Int](repeating: 0, count: groups.count + 1)
        for index in stride(from: groups.count - 1, through: 0, by: -1) {
            guard groups[index] == 0 else { continue }
            lengths[index] = lengths[index + 1] + 1
        }
        return Array(lengths.dropLast())
    }

    private static func longestZeroRunStart(_ lengths: [Int]) -> Int {
        var bestIndex = 0
        for index in lengths.indices where lengths[index] > lengths[bestIndex] {
            bestIndex = index
        }
        return bestIndex
    }

    private static func renderPlain(_ groups: [UInt16]) -> String {
        groups.map { String($0, radix: 16) }.joined(separator: ":")
    }

    private static func renderCompressed(_ groups: [UInt16], runStart: Int, runLength: Int) -> String {
        let head = renderPlain(Array(groups[0..<runStart]))
        let tail = renderPlain(Array(groups[(runStart + runLength)...]))
        return head + "::" + tail
    }
}
