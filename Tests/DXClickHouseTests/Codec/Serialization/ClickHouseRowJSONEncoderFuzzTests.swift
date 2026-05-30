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
import Testing

// Property-style coverage for `ClickHouseRowJSONEncoder`. The curated
// unit tests pin down each documented value convention; these fuzz
// tests run the encoder over randomly-generated column data so any
// per-type encoding drift, alignment edge case, or composite recursion
// bug surfaces deterministically (seed → exact payload).
@Suite("ClickHouse row JSON encoder — fuzz")
struct ClickHouseRowJSONEncoderFuzzTests {

    @Test(
        "random Int64 columns survive encode → JSONSerialization round-trip across the full signed range",
        arguments: [10_001, 10_002, 10_003, 10_004] as [UInt64]
    )
    func int64Fuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<200).map { _ in Int64.random(in: .min ... .max, using: &rng) }
        let block = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "n", column: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: values)),
        ])
        for index in values.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            // JSONSerialization bridges Int64 through NSNumber; both
            // Int64 and Int representations are accepted in any 64-bit
            // host configuration the tests run on.
            let raw = try #require(parsed?["n"])
            let asInt64 = (raw as? Int64) ?? (raw as? NSNumber)?.int64Value
            #expect(asInt64 == values[index], "seed=\(seed) index=\(index) value=\(values[index])")
        }
    }

    @Test(
        "random UInt64 columns above Int64.max stay distinct from negative-Int64 values through the JSON path",
        arguments: [11_001, 11_002, 11_003] as [UInt64]
    )
    func uint64HighFuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<100).map { _ in UInt64.random(in: UInt64(Int64.max) + 1 ... UInt64.max, using: &rng) }
        let block = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "u", column: ClickHouseFixedWidthIntegerColumn<UInt64>(spec: .uint64, values: values)),
        ])
        for index in values.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let raw = try #require(parsed?["u"])
            let asUInt64 = (raw as? UInt64) ?? (raw as? NSNumber)?.uint64Value
            #expect(asUInt64 == values[index], "seed=\(seed) index=\(index) value=\(values[index])")
        }
    }

    @Test(
        "random Nullable(Int32) rows preserve null/value masking through the JSON path",
        arguments: [12_001, 12_002, 12_003] as [UInt64]
    )
    func nullableInt32Fuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let optionals: [Int32?] = (0..<100).map { _ in
            // 30% nulls, 70% values.
            UInt8.random(in: 0...9, using: &rng) < 3 ? nil : Int32.random(in: .min ... .max, using: &rng)
        }
        let nullMask = optionals.map { $0 == nil }
        let inner = optionals.map { $0 ?? 0 }
        let nullable = ClickHouseNullableColumn(
            spec: .nullable(of: .int32),
            innerSpec: .int32,
            nullMask: nullMask,
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: inner)
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "n", column: nullable)])
        for index in optionals.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            if optionals[index] == nil {
                #expect(parsed?["n"] is NSNull, "seed=\(seed) index=\(index) expected NSNull")
            } else {
                let raw = try #require(parsed?["n"])
                let asInt32 = (raw as? Int).map { Int32($0) } ?? (raw as? Int32) ?? (raw as? NSNumber)?.int32Value
                #expect(asInt32 == optionals[index], "seed=\(seed) index=\(index)")
            }
        }
    }

    @Test(
        "random Array(Int32) rows preserve per-row offset slicing under the JSON encoder",
        arguments: [13_001, 13_002, 13_003] as [UInt64]
    )
    func arrayOfInt32Fuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let arrays: [[Int32]] = (0..<50).map { _ in
            let length = Int.random(in: 0...12, using: &rng)
            return (0..<length).map { _ in Int32.random(in: .min ... .max, using: &rng) }
        }
        var offsets: [UInt64] = []
        offsets.reserveCapacity(arrays.count)
        var cumulative: UInt64 = 0
        var flat: [Int32] = []
        for arr in arrays {
            cumulative &+= UInt64(arr.count)
            offsets.append(cumulative)
            flat.append(contentsOf: arr)
        }
        let array = ClickHouseArrayColumn(
            spec: .array(of: .int32),
            elementSpec: .int32,
            offsets: offsets,
            inner: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: flat)
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "a", column: array)])
        for index in arrays.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let raw = try #require(parsed?["a"] as? [Any], "seed=\(seed) index=\(index) expected JSON array")
            #expect(raw.count == arrays[index].count, "seed=\(seed) index=\(index) length")
            for (rawElement, expected) in zip(raw, arrays[index]) {
                let asInt32 = (rawElement as? Int).map { Int32($0) } ?? (rawElement as? NSNumber)?.int32Value
                #expect(asInt32 == expected, "seed=\(seed) index=\(index)")
            }
        }
    }

    @Test(
        "random LowCardinality(String) columns resolve every row through the dictionary",
        arguments: [14_001, 14_002, 14_003] as [UInt64]
    )
    func lowCardinalityStringFuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let dictionarySize = Int.random(in: 1...20, using: &rng)
        let dictionary = (0..<dictionarySize).map { i in "v_\(i)_\(UInt32.random(in: 0...UInt32.max, using: &rng))" }
        let rowCount = 200
        let indices: [UInt64] = (0..<rowCount).map { _ in UInt64(Int.random(in: 0..<dictionarySize, using: &rng)) }
        let lc = ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: .string),
            innerSpec: .string,
            dictionary: ClickHouseStringColumn(values: dictionary),
            indices: indices
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "lc", column: lc)])
        for index in indices.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let raw = try #require(parsed?["lc"] as? String)
            #expect(raw == dictionary[Int(indices[index])], "seed=\(seed) index=\(index)")
        }
    }

    @Test(
        "random Map(String, Int64) rows survive encode → JSON object round-trip with key/value pairing intact",
        arguments: [15_001, 15_002, 15_003] as [UInt64]
    )
    func mapStringInt64Fuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        // Build random per-row dictionaries, then flatten into the
        // (offsets, keys-column, values-column) shape the wire uses.
        let perRow: [[String: Int64]] = (0..<60).map { _ in
            let entries = Int.random(in: 0...8, using: &rng)
            var dict: [String: Int64] = [:]
            dict.reserveCapacity(entries)
            for entry in 0..<entries {
                dict["k_\(entry)_\(UInt8.random(in: 0...255, using: &rng))"] = Int64.random(in: .min ... .max, using: &rng)
            }
            return dict
        }
        var offsets: [UInt64] = []
        offsets.reserveCapacity(perRow.count)
        var cumulative: UInt64 = 0
        var keys: [String] = []
        var values: [Int64] = []
        for dict in perRow {
            cumulative &+= UInt64(dict.count)
            offsets.append(cumulative)
            for (k, v) in dict {
                keys.append(k)
                values.append(v)
            }
        }
        let map = ClickHouseMapColumn(
            spec: .map(key: .string, value: .int64),
            keySpec: .string,
            valueSpec: .int64,
            offsets: offsets,
            keys: ClickHouseStringColumn(values: keys),
            values: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: values)
        )
        let block = ClickHouseBlock(blockInfo: .init(), columns: [.init(name: "m", column: map)])
        for index in perRow.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let rawMap = try #require(parsed?["m"] as? [String: Any], "seed=\(seed) index=\(index) expected JSON object")
            #expect(rawMap.count == perRow[index].count, "seed=\(seed) index=\(index) entry count")
            for (key, expectedValue) in perRow[index] {
                let rawValue = try #require(rawMap[key], "seed=\(seed) index=\(index) missing key \(key)")
                let asInt64 = (rawValue as? Int).map { Int64($0) } ?? (rawValue as? Int64) ?? (rawValue as? NSNumber)?.int64Value
                #expect(asInt64 == expectedValue, "seed=\(seed) index=\(index) key=\(key)")
            }
        }
    }

    @Test(
        "random Float64 values round-trip with bit-exact equality through JSONDecoder (no NaN/Inf)",
        arguments: [16_001, 16_002, 16_003] as [UInt64]
    )
    func float64Fuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<100).map { _ -> Double in
            // Skip NaN/Inf because the encoder rejects them with a
            // typed error; the server-side codec test covers this
            // convention separately.
            Double.random(in: -1e6 ... 1e6, using: &rng)
        }
        let block = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "f", column: ClickHouseFloat64Column(values: values)),
        ])
        // Read back with the same JSONDecoder that the production
        // `decodedRows` path uses. Foundation's `JSONSerialization`
        // parser loses 1 ULP on most random Float64 values on Linux
        // (see ClickHouseRowJSONEncoder.swift); the encoder writes
        // the round-trip-safe representation but only `JSONDecoder`
        // parses it back bit-exact.
        struct Row: Decodable { let f: Double }
        let decoder = JSONDecoder()
        for index in values.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try decoder.decode(Row.self, from: payload)
            #expect(parsed.f == values[index], "seed=\(seed) index=\(index) value=\(values[index])")
        }
    }

    @Test(
        "random String columns including 4-byte UTF-8 codepoints round-trip through the JSON encoder",
        arguments: [17_001, 17_002, 17_003] as [UInt64]
    )
    func utf8StringFuzz(seed: UInt64) throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values: [String] = (0..<60).map { _ in
            let length = Int.random(in: 0...32, using: &rng)
            var scalars: [Unicode.Scalar] = []
            scalars.reserveCapacity(length)
            for _ in 0..<length {
                let pool: [ClosedRange<UInt32>] = [
                    0x20...0x7E,
                    0xA0...0x7FF,
                    0x800...0xD7FF,
                    0x10000...0x10FFFF,
                ]
                let bucket = pool[Int.random(in: 0..<pool.count, using: &rng)]
                let raw = UInt32.random(in: bucket, using: &rng)
                if let scalar = Unicode.Scalar(raw) {
                    scalars.append(scalar)
                }
            }
            return String(String.UnicodeScalarView(scalars))
        }
        let block = ClickHouseBlock(blockInfo: .init(), columns: [
            .init(name: "s", column: ClickHouseStringColumn(values: values)),
        ])
        for index in values.indices {
            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: index)
            let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let raw = try #require(parsed?["s"] as? String, "seed=\(seed) index=\(index) expected String")
            #expect(raw == values[index], "seed=\(seed) index=\(index)")
        }
    }

}
