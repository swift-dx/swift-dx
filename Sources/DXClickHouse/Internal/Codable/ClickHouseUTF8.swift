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

// Builds a Swift String from a column's raw bytes. A drop-in, behaviour-
// identical replacement for `String(decoding: bytes, as: UTF8.self)` that is
// faster for the common case of ASCII text: a single pass confirms every byte
// is below 0x80 (ASCII is valid UTF-8), then the String is built straight from
// the bytes with no validation. Any byte at or above 0x80 means the value may
// be multi-byte UTF-8 or arbitrary binary, so it falls back to the validating
// decoder, which repairs malformed sequences exactly as before. The String
// produced is identical for every input; only the ASCII path is faster.
@usableFromInline enum ClickHouseUTF8 {

    @inline(__always)
    @usableFromInline
    static func decode(_ bytes: [UInt8]) -> String {
        bytes.withUnsafeBytes { decode($0) }
    }

    // @inlinable so the whole String materialization inlines into
    // ClickHouseRawBlock.string and thence into the consumer's decodeFused loop,
    // rather than emitting one cross-module call per row. Measured: with only
    // the symbol exposed (a per-row call) the fused string decode sat ~23ms
    // above the hand-written raw-pointer ceiling on a 1M-row block; inlining the
    // body closes that. The helpers are @usableFromInline so the inlined body
    // can reference them across the module boundary.
    @inlinable
    @inline(__always)
    static func decode(_ buffer: UnsafeRawBufferPointer) -> String {
        if isASCII(buffer) {
            return buildUnchecked(buffer)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    @usableFromInline
    @inline(__always)
    static func isASCII(_ buffer: UnsafeRawBufferPointer) -> Bool {
        for byte in buffer where byte >= 0x80 { return false }
        return true
    }

    @usableFromInline
    @inline(__always)
    static func buildUnchecked(_ buffer: UnsafeRawBufferPointer) -> String {
        String(unsafeUninitializedCapacity: buffer.count) { destination in
            guard let target = destination.baseAddress, let source = buffer.baseAddress else { return 0 }
            target.update(from: source.assumingMemoryBound(to: UInt8.self), count: buffer.count)
            return buffer.count
        }
    }
}
