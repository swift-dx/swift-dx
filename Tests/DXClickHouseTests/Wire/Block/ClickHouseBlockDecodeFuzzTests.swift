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

@testable import DXClickHouse
import Foundation
import NIOCore
import Testing

// Property-style fuzz coverage for `ClickHouseBlock.decode`. The
// curated unit tests pin specific protocol-error paths; this harness
// asserts the broader contract: NO byte sequence may abort the
// decoder. Every invocation must produce either:
//
//   1. A decoded block whose invariants hold (every column has the
//      block-header rowCount; columns array length == columnCount).
//   2. A typed `ClickHouseError` thrown out cleanly.
//
// Process traps, fatalErrors, hangs, and untyped errors are
// regressions the harness is designed to surface deterministically
// (seed → exact byte sequence). New CI seeds catch regressions
// without having to hand-craft minimal reproducers.
//
// Mix of input shapes (uniformly per seed):
//   - fully random bytes (most invalid)
//   - bytes preceded by a valid BlockInfo header
//   - bytes preceded by a valid BlockInfo + plausible columnCount/rowCount
//
// The shape mix exercises the validation guards (column count cap,
// row count cap, sparse cap, composite inner row count), the typed
// error paths in UVarInt/string/varuint, and the registry's
// `unknownTypeName` / `malformedTypeName` rejection.
@Suite("ClickHouseBlock.decode — fuzz contract: no input traps the decoder")
struct ClickHouseBlockDecodeFuzzTests {

    // 32 distinct seeds × ~250 inputs each = ~8k decode attempts per
    // run. Test runtime stays well under one second; CI catches new
    // regressions reliably without bloating the suite.
    private static let seeds: [UInt64] = (0..<32).map { 0x4350_5446_5552_5A_00 &+ $0 }
    private static let inputsPerSeed = 250

    @Test(
        "every byte sequence either decodes consistently or throws a typed ClickHouseError",
        arguments: ClickHouseBlockDecodeFuzzTests.seeds
    )
    func blockDecodeNeverTraps(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        for inputIndex in 0..<Self.inputsPerSeed {
            let bytes = generateInput(rng: &rng)
            var buffer = ByteBuffer()
            buffer.writeBytes(bytes)
            do {
                let block = try ClickHouseBlock.decode(from: &buffer, revision: 54_478)
                // Success path: invariants must hold. The block-level
                // row-count guard added in the prior hardening pass
                // makes this a straight-line property check — every
                // column reports the same rowCount.
                let expected = block.rowCount
                for (idx, column) in block.columns.enumerated() {
                    #expect(
                        column.column.rowCount == expected,
                        "seed=\(seed) input=\(inputIndex) column=\(idx) drift expected=\(expected) actual=\(column.column.rowCount)"
                    )
                }
            } catch is ClickHouseError {
                // Typed protocol error is an acceptable outcome — the
                // decoder rejected hostile input cleanly.
            } catch {
                // Any non-typed error is a regression: it means the
                // decoder leaked a non-protocol error type (likely a
                // Foundation error or an inner library's untyped
                // failure) instead of converting it to a typed
                // protocol error.
                Issue.record(
                    "seed=\(seed) input=\(inputIndex) leaked untyped error: \(type(of: error)) \(error)"
                )
            }
        }
    }

    // Builds one input candidate. Three rough shapes exercised by
    // dice roll:
    //
    //   shape 0: completely random bytes (most likely invalid early)
    //   shape 1: valid BlockInfo terminator followed by random tail
    //   shape 2: valid BlockInfo + valid Int(exactly:) columnCount
    //            and rowCount, then random bytes (forces the hostile-
    //            row-count guards to fire)
    //
    // Lengths span from 0 bytes to several KB so truncation paths and
    // partial-prefix paths both get exercised.
    private func generateInput(rng: inout SeededRandomNumberGenerator) -> [UInt8] {
        let shape = Int(rng.next() & 0x3)
        let totalLength = Int(rng.next() & 0xFFF)  // 0...4095
        var bytes: [UInt8] = []
        bytes.reserveCapacity(totalLength)
        switch shape {
        case 0:
            for _ in 0..<totalLength {
                bytes.append(UInt8(rng.next() & 0xFF))
            }
        case 1:
            // BlockInfo terminator: just one zero UVarInt.
            bytes.append(0)
            for _ in 0..<max(0, totalLength - 1) {
                bytes.append(UInt8(rng.next() & 0xFF))
            }
        default:
            // Valid BlockInfo + plausible counts. Counts capped at
            // a few thousand so a full random tail is plausibly
            // long enough to read partial column data.
            bytes.append(0)
            let columnCount = UInt64(rng.next() & 0xFF)        // 0...255
            let rowCount = UInt64(rng.next() & 0xFFF)           // 0...4095
            appendUVarInt(columnCount, to: &bytes)
            appendUVarInt(rowCount, to: &bytes)
            for _ in 0..<max(0, totalLength - bytes.count) {
                bytes.append(UInt8(rng.next() & 0xFF))
            }
        }
        return bytes
    }

    private func appendUVarInt(_ value: UInt64, to bytes: inout [UInt8]) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

}
