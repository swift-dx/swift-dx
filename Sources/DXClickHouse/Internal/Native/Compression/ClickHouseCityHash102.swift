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

// CityHash version 1.0.2 — the variant ClickHouse uses for its
// compression frame checksum. The 1.1+ algorithms produce
// different results and would be rejected by the server, so we
// pin to 1.0.2 explicitly. Source-of-truth port from
// `github.com/go-faster/city@v1.0.1` (files 64.go + ch_128.go).
// All arithmetic uses Swift's wrapping operators (`&*`, `&+`, `&-`)
// since the algorithm relies on unsigned wrap semantics.
enum ClickHouseCityHash102 {

    static func hash128(_ bytes: ByteBufferView) -> ClickHouseCityHash128 {
        let length = bytes.count
        if length >= 16 {
            let low = fetch64(bytes, at: 0) ^ k3
            let high = fetch64(bytes, at: 8)
            return cityHash128WithSeed(
                bytes,
                offset: 16,
                length: length - 16,
                seed: ClickHouseCityHash128(low: low, high: high)
            )
        }
        if length >= 8 {
            let low = fetch64(bytes, at: 0) ^ (UInt64(length) &* k0)
            let high = fetch64(bytes, at: length - 8) ^ k1
            return cityHash128WithSeed(
                bytes,
                offset: 0,
                length: 0,
                seed: ClickHouseCityHash128(low: low, high: high)
            )
        }
        return cityHash128WithSeed(
            bytes,
            offset: 0,
            length: length,
            seed: ClickHouseCityHash128(low: k0, high: k1)
        )
    }

    private static let k0: UInt64 = 0xc3a5_c85c_97cb_3127
    private static let k1: UInt64 = 0xb492_b66f_be98_f273
    private static let k2: UInt64 = 0x9ae1_6a3b_2f90_404f
    private static let k3: UInt64 = 0xc949_d7c7_509e_6557

    private static func fetch64(_ bytes: ByteBufferView, at index: Int) -> UInt64 {
        let base = bytes.startIndex + index
        return UInt64(bytes[base])
            | (UInt64(bytes[base + 1]) << 8)
            | (UInt64(bytes[base + 2]) << 16)
            | (UInt64(bytes[base + 3]) << 24)
            | (UInt64(bytes[base + 4]) << 32)
            | (UInt64(bytes[base + 5]) << 40)
            | (UInt64(bytes[base + 6]) << 48)
            | (UInt64(bytes[base + 7]) << 56)
    }

    private static func fetch32(_ bytes: ByteBufferView, at index: Int) -> UInt32 {
        let base = bytes.startIndex + index
        return UInt32(bytes[base])
            | (UInt32(bytes[base + 1]) << 8)
            | (UInt32(bytes[base + 2]) << 16)
            | (UInt32(bytes[base + 3]) << 24)
    }

    private static func rotate(_ value: UInt64, _ shift: Int) -> UInt64 {
        shift == 0 ? value : ((value >> shift) | (value << (64 - shift)))
    }

    private static func shiftMix(_ value: UInt64) -> UInt64 {
        value ^ (value >> 47)
    }

    private static func hashLen16(_ u: UInt64, _ v: UInt64) -> UInt64 {
        let mul: UInt64 = 0x9ddf_ea08_eb38_2d69
        var a = (u ^ v) &* mul
        a ^= (a >> 47)
        var b = (v ^ a) &* mul
        b ^= (b >> 47)
        b = b &* mul
        return b
    }

    @inline(__always)
    private static func hashLen0to16(_ bytes: ByteBufferView, offset: Int, length: Int) -> UInt64 {
        if length > 8 { return hashLen9to16(bytes, offset: offset, length: length) }
        return hashLen0to8(bytes, offset: offset, length: length)
    }

    @inline(__always)
    private static func hashLen9to16(_ bytes: ByteBufferView, offset: Int, length: Int) -> UInt64 {
        let a = fetch64(bytes, at: offset)
        let b = fetch64(bytes, at: offset + length - 8)
        return hashLen16(a, rotate(b &+ UInt64(length), length)) ^ b
    }

    @inline(__always)
    private static func hashLen0to8(_ bytes: ByteBufferView, offset: Int, length: Int) -> UInt64 {
        if length >= 4 { return hashLen4to8(bytes, offset: offset, length: length) }
        if length > 0 { return hashLen1to3(bytes, offset: offset, length: length) }
        return k2
    }

    @inline(__always)
    private static func hashLen4to8(_ bytes: ByteBufferView, offset: Int, length: Int) -> UInt64 {
        let a = UInt64(fetch32(bytes, at: offset))
        let b = UInt64(fetch32(bytes, at: offset + length - 4))
        return hashLen16(UInt64(length) &+ (a << 3), b)
    }

    @inline(__always)
    private static func hashLen1to3(_ bytes: ByteBufferView, offset: Int, length: Int) -> UInt64 {
        let base = bytes.startIndex + offset
        let a = bytes[base]
        let b = bytes[base + (length >> 1)]
        let c = bytes[base + length - 1]
        let y: UInt32 = UInt32(a) &+ (UInt32(b) << 8)
        let z: UInt32 = UInt32(length) &+ (UInt32(c) << 2)
        return shiftMix(UInt64(y) &* k2 ^ UInt64(z) &* k3) &* k2
    }

    // 16..127-byte path: seeded murmur-style hash. The unconditional
    // first 16-byte mix is followed by a loop that consumes 16 bytes
    // per iteration until the length-16 reservation is exhausted.
    private static func cityMurmur(
        _ bytes: ByteBufferView,
        offset: Int,
        length: Int,
        seed: ClickHouseCityHash128
    ) -> ClickHouseCityHash128 {
        var a = seed.low
        var b = seed.high
        var c: UInt64 = 0
        var d: UInt64 = 0
        let remaining = length - 16
        if remaining <= 0 {
            cityMurmurShort(bytes, offset: offset, length: length, a: &a, b: b, c: &c, d: &d)
        } else {
            cityMurmurLong(bytes, offset: offset, length: length, remaining: remaining, a: &a, b: &b, c: &c, d: &d)
        }
        a = hashLen16(a, c)
        b = hashLen16(d, b)
        return ClickHouseCityHash128(low: a ^ b, high: hashLen16(b, a))
    }

    @inline(__always)
    private static func cityMurmurShort(
        _ bytes: ByteBufferView,
        offset: Int,
        length: Int,
        a: inout UInt64,
        b: UInt64,
        c: inout UInt64,
        d: inout UInt64
    ) {
        a = shiftMix(a &* k1) &* k1
        c = b &* k1 &+ hashLen0to16(bytes, offset: offset, length: length)
        let folded: UInt64 = length >= 8 ? fetch64(bytes, at: offset) : c
        d = shiftMix(a &+ folded)
    }

    @inline(__always)
    private static func cityMurmurLong(
        _ bytes: ByteBufferView,
        offset: Int,
        length: Int,
        remaining: Int,
        a: inout UInt64,
        b: inout UInt64,
        c: inout UInt64,
        d: inout UInt64
    ) {
        c = hashLen16(fetch64(bytes, at: offset + length - 8) &+ k1, a)
        d = hashLen16(b &+ UInt64(length), c &+ fetch64(bytes, at: offset + length - 16))
        a = a &+ d
        var cursor = offset
        var remainingMutable = remaining
        while remainingMutable > 0 {
            cityMurmurChunk(bytes, cursor: cursor, a: &a, b: &b, c: &c, d: &d)
            cursor += 16
            remainingMutable -= 16
        }
    }

    @inline(__always)
    private static func cityMurmurChunk(
        _ bytes: ByteBufferView,
        cursor: Int,
        a: inout UInt64,
        b: inout UInt64,
        c: inout UInt64,
        d: inout UInt64
    ) {
        a ^= shiftMix(fetch64(bytes, at: cursor) &* k1) &* k1
        a = a &* k1
        b ^= a
        c ^= shiftMix(fetch64(bytes, at: cursor + 8) &* k1) &* k1
        c = c &* k1
        d ^= c
    }

    private static func cityHash128WithSeed(
        _ bytes: ByteBufferView,
        offset: Int,
        length: Int,
        seed: ClickHouseCityHash128
    ) -> ClickHouseCityHash128 {
        if length < 128 {
            return cityMurmur(bytes, offset: offset, length: length, seed: seed)
        }
        return cityHash128WithSeedLong(bytes, offset: offset, length: length, seed: seed)
    }

    private static func cityHash128WithSeedLong(
        _ bytes: ByteBufferView,
        offset: Int,
        length: Int,
        seed: ClickHouseCityHash128
    ) -> ClickHouseCityHash128 {
        var v = WeakHash(low: 0, high: 0)
        var w = WeakHash(low: 0, high: 0)
        var x = seed.low
        var y = seed.high
        var z: UInt64 = UInt64(length) &* k1
        v.low = rotate(y ^ k1, 49) &* k1 &+ fetch64(bytes, at: offset)
        v.high = rotate(v.low, 42) &* k1 &+ fetch64(bytes, at: offset + 8)
        w.low = rotate(y &+ z, 35) &* k1 &+ x
        w.high = rotate(x &+ fetch64(bytes, at: offset + 88), 53) &* k1
        var cursor = offset
        var remaining = length
        runLongMainLoop(bytes, cursor: &cursor, remaining: &remaining, v: &v, w: &w, x: &x, y: &y, z: &z)
        y = y &+ rotate(w.low, 37) &* k0 &+ z
        x = x &+ rotate(v.low &+ z, 49) &* k0
        runLongTailLoop(bytes, offset: offset, length: length, remaining: remaining, v: &v, w: &w, x: &x, y: &y)
        x = hashLen16(x, v.low)
        y = hashLen16(y, w.low)
        return ClickHouseCityHash128(
            low: hashLen16(x &+ v.high, w.high) &+ y,
            high: hashLen16(x &+ w.high, y &+ v.high)
        )
    }

    @inline(__always)
    private static func runLongMainLoop(
        _ bytes: ByteBufferView,
        cursor: inout Int,
        remaining: inout Int,
        v: inout WeakHash,
        w: inout WeakHash,
        x: inout UInt64,
        y: inout UInt64,
        z: inout UInt64
    ) {
        repeat {
            longLoopStep(bytes, cursor: &cursor, remaining: &remaining, v: &v, w: &w, x: &x, y: &y, z: &z)
            longLoopStep(bytes, cursor: &cursor, remaining: &remaining, v: &v, w: &w, x: &x, y: &y, z: &z)
        } while remaining >= 128
    }

    @inline(__always)
    private static func longLoopStep(
        _ bytes: ByteBufferView,
        cursor: inout Int,
        remaining: inout Int,
        v: inout WeakHash,
        w: inout WeakHash,
        x: inout UInt64,
        y: inout UInt64,
        z: inout UInt64
    ) {
        x = rotate(x &+ y &+ v.low &+ fetch64(bytes, at: cursor + 16), 37) &* k1
        y = rotate(y &+ v.high &+ fetch64(bytes, at: cursor + 48), 42) &* k1
        x ^= w.high
        y ^= v.low
        z = rotate(z ^ w.low, 33)
        v = weakHashLen32WithSeeds(bytes, offset: cursor, a: v.high &* k1, b: x &+ w.low)
        w = weakHashLen32WithSeeds(bytes, offset: cursor + 32, a: z &+ w.high, b: y)
        swap(&z, &x)
        cursor += 64
        remaining -= 64
    }

    @inline(__always)
    private static func runLongTailLoop(
        _ bytes: ByteBufferView,
        offset: Int,
        length: Int,
        remaining: Int,
        v: inout WeakHash,
        w: inout WeakHash,
        x: inout UInt64,
        y: inout UInt64
    ) {
        var i = 0
        while i < remaining {
            i += 32
            y = rotate(y &- x, 42) &* k0 &+ v.high
            w.low = w.low &+ fetch64(bytes, at: offset + length - i + 16)
            x = rotate(x, 49) &* k0 &+ w.low
            w.low = w.low &+ v.low
            v = weakHashLen32WithSeeds(
                bytes,
                offset: offset + length - i,
                a: v.low,
                b: v.high
            )
        }
    }

    private struct WeakHash {

        var low: UInt64
        var high: UInt64

    }

    // Note: rotation constants 21 and 44 (NOT 51 and 23) — port from
    // canonical `go-faster/city/64.go:weakHash32Seeds`. A previous
    // port attempt used 51/23 here and produced wrong 128-bit hashes
    // for inputs where the main loop runs (length >= 128).
    private static func weakHashLen32WithSeeds(
        _ bytes: ByteBufferView,
        offset: Int,
        a aSeed: UInt64,
        b bSeed: UInt64
    ) -> WeakHash {
        let w = fetch64(bytes, at: offset)
        let x = fetch64(bytes, at: offset + 8)
        let y = fetch64(bytes, at: offset + 16)
        let z = fetch64(bytes, at: offset + 24)
        var a = aSeed &+ w
        var b = rotate(bSeed &+ a &+ z, 21)
        let c = a
        a = a &+ x
        a = a &+ y
        b = b &+ rotate(a, 44)
        return WeakHash(low: a &+ z, high: b &+ c)
    }

}
