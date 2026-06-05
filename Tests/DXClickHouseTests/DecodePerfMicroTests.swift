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

// Isolates the Codable decode cost from network and wire parsing: builds the
// typed columns once in memory, then times decodeRows over them. Gated on
// DX_DECODE_PERF so it never runs in the normal suite. Run with:
//   DX_DECODE_PERF=1 swift test -c release --filter DecodePerfMicroTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DX_DECODE_PERF"] != nil))
struct DecodePerfMicroTests {

    private struct Row: Decodable { let id: UInt64; let name: String; let value: Double }

    @Test("decodeRows throughput for a UInt64/String/Float64 block")
    func decodeThroughput() throws {
        let count = 1_000_000
        var ids: [UInt64] = []; ids.reserveCapacity(count)
        var names: [[UInt8]] = []; names.reserveCapacity(count)
        var values: [Double] = []; values.reserveCapacity(count)
        for n in 0..<count {
            ids.append(UInt64(n))
            names.append(Array("row_\(n % 1000)".utf8))
            values.append(Double(n) * 1.5)
        }
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .uint64(ids)),
            ClickHouseNamedColumn(name: "name", column: .string(names)),
            ClickHouseNamedColumn(name: "value", column: .float64(values)),
        ]
        // Warm up.
        _ = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: count)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let rows = try ClickHouseCodableDecoder.decodeRows(type: Row.self, columns: columns, rowCount: count)
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            best = min(best, seconds)
            #expect(rows.count == count)
        }
        print(String(format: "[DECODE] %d rows in %.3fs = %.2f M rows/s", count, best, Double(count) / best / 1e6))
    }

    // Ceiling experiment: build the same rows by reading the typed columns
    // directly, with no Codable container per row. Shows how fast a columnar
    // fast-path could go relative to the 0.47 M rows/s Codable path.
    @Test("direct columnar read ceiling (no Codable container per row)")
    func directColumnarCeiling() throws {
        let count = 1_000_000
        var ids: [UInt64] = []; ids.reserveCapacity(count)
        var names: [[UInt8]] = []; names.reserveCapacity(count)
        var values: [Double] = []; values.reserveCapacity(count)
        for n in 0..<count {
            ids.append(UInt64(n)); names.append(Array("row_\(n % 1000)".utf8)); values.append(Double(n) * 1.5)
        }
        let idCol = ClickHouseTypedColumn.uint64(ids)
        let nameCol = ClickHouseTypedColumn.string(names)
        let valueCol = ClickHouseTypedColumn.float64(values)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = ContinuousClock.now
            var rows: [Row] = []; rows.reserveCapacity(count)
            guard case .uint64(let ic) = idCol, case .string(let nc) = nameCol, case .float64(let vc) = valueCol else { return }
            for i in 0..<count {
                rows.append(Row(id: ic[i], name: String(decoding: nc[i], as: UTF8.self), value: vc[i]))
            }
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            #expect(rows.count == count)
        }
        print(String(format: "[DECODE-DIRECT] %d rows in %.3fs = %.2f M rows/s", count, best, Double(count) / best / 1e6))
    }

    // Hand-written conformance standing in for what @ClickHouseRow generates.
    private struct FastRow: ClickHouseRowDecodable {
        let id: UInt64; let name: String; let value: Double
        static let clickHouseColumnNames = ["id", "name", "value"]
        static func decodeBlock(_ block: ClickHouseColumnBlock) throws(ClickHouseError) -> [FastRow] {
            let ids = try block.uint64(0); let names = try block.strings(1); let values = try block.double(2)
            var rows = [FastRow](); rows.reserveCapacity(block.count)
            for i in 0..<block.count { rows.append(FastRow(id: ids[i], name: names[i], value: values[i])) }
            return rows
        }
    }

    @Test("columnar fast-path decode throughput (ClickHouseRowDecodable)")
    func fastPathThroughput() throws {
        let count = 1_000_000
        var ids: [UInt64] = []; ids.reserveCapacity(count)
        var names: [[UInt8]] = []; names.reserveCapacity(count)
        var values: [Double] = []; values.reserveCapacity(count)
        for n in 0..<count {
            ids.append(UInt64(n)); names.append(Array("row_\(n % 1000)".utf8)); values.append(Double(n) * 1.5)
        }
        let columns = [
            ClickHouseNamedColumn(name: "id", column: .uint64(ids)),
            ClickHouseNamedColumn(name: "name", column: .string(names)),
            ClickHouseNamedColumn(name: "value", column: .float64(values)),
        ]
        _ = try ClickHouseCodableDecoder.decodeFastRows(type: FastRow.self, columns: columns, rowCount: count)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let rows = try ClickHouseCodableDecoder.decodeFastRows(type: FastRow.self, columns: columns, rowCount: count)
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            #expect(rows.count == count)
        }
        print(String(format: "[DECODE-FAST] %d rows in %.3fs = %.2f M rows/s", count, best, Double(count) / best / 1e6))
    }

    private struct EncRow: Codable, Sendable { let id: UInt64; let name: String; let value: Double }

    @Test("Codable encode throughput for a UInt64/String/Float64 block")
    func encodeThroughput() throws {
        let count = 1_000_000
        var rows: [EncRow] = []; rows.reserveCapacity(count)
        for n in 0..<count { rows.append(EncRow(id: UInt64(n), name: "row_\(n % 1000)", value: Double(n) * 1.5)) }
        _ = try ClickHouseRowEncoder().encode(rows)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let columns = try ClickHouseRowEncoder().encode(rows)
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            #expect(columns.count == 3)
        }
        print(String(format: "[ENCODE] %d rows in %.3fs = %.2f M rows/s", count, best, Double(count) / best / 1e6))
    }

    // Isolates the fast-path WRITE encode CPU (no network): ColumnSink build
    // (including the [String]->[[UInt8]] materialization) + block serialization.
    // Split into the string-array materialization, the numeric-only encode, and
    // the full encode so the dominant cost is visible against C++.
    @Test("fast write encode throughput (sink + block serialize)")
    func writeEncodeThroughput() throws {
        let count = 1_000_000
        var ids = [UInt64](); ids.reserveCapacity(count)
        var names = [String](); names.reserveCapacity(count)
        var values = [Double](); values.reserveCapacity(count)
        for n in 0..<count { ids.append(UInt64(n)); names.append("row_\(n % 1000)"); values.append(Double(n) * 1.5) }
        let revision = ClickHouseQueryBuilder.revision

        Self.bench("WRITE-STRINGMAP", count: count) {
            let materialized = names.map { Array($0.utf8) }
            return materialized.count
        }
        Self.bench("WRITE-ENCODE-NUMERIC", count: count) {
            var sink = ClickHouseColumnSink()
            sink.uint64("id", ids)
            sink.double("value", values)
            let packet = (try? ClickHouseBlockWriter.encodeDataPacketTerminated(columns: sink.columns, revision: revision)) ?? []
            return packet.isEmpty ? 0 : count
        }
        Self.bench("WRITE-ENCODE-FULL", count: count) {
            var sink = ClickHouseColumnSink()
            sink.uint64("id", ids)
            sink.string("name", names)
            sink.double("value", values)
            let packet = (try? ClickHouseBlockWriter.encodeDataPacketTerminated(columns: sink.columns, revision: revision)) ?? []
            return packet.isEmpty ? 0 : count
        }
    }

    private struct FusedRow: ClickHouseFusedDecodable, Sendable {
        let id: UInt64; let name: String; let value: Double
        static let clickHouseColumnNames = ["id", "name", "value"]
        static func decodeFused(_ block: ClickHouseRawBlock) throws(ClickHouseError) -> [FusedRow] {
            var rows = [FusedRow](); rows.reserveCapacity(block.count)
            for i in 0..<block.count {
                rows.append(FusedRow(id: block.uint64(0, i), name: block.string(1, i), value: block.double(2, i)))
            }
            return rows
        }
    }

    private static func buildFusedBody(count: Int) -> [UInt8] {
        var body: [UInt8] = []
        body.reserveCapacity(count * 24)
        for n in 0..<count { withUnsafeBytes(of: UInt64(n).littleEndian) { body.append(contentsOf: $0) } }
        for n in 0..<count {
            let name = Array("row_\(n % 1000)".utf8)
            ClickHouseWire.writeUVarInt(UInt64(name.count), into: &body)
            body.append(contentsOf: name)
        }
        for n in 0..<count { withUnsafeBytes(of: (Double(n) * 1.5).bitPattern.littleEndian) { body.append(contentsOf: $0) } }
        return body
    }

    private struct FusedRowNoStr: ClickHouseFusedDecodable, Sendable {
        let id: UInt64; let value: Double
        static let clickHouseColumnNames = ["id", "value"]
        static func decodeFused(_ block: ClickHouseRawBlock) throws(ClickHouseError) -> [FusedRowNoStr] {
            var rows = [FusedRowNoStr](); rows.reserveCapacity(block.count)
            for i in 0..<block.count { rows.append(FusedRowNoStr(id: block.uint64(0, i), value: block.double(1, i))) }
            return rows
        }
    }

    private static func bench(_ label: String, count: Int, iterations: Int = 5, _ body: () -> Int) {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            let produced = body()
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            precondition(produced == count)
        }
        print(String(format: "[%@] %d rows in %.4fs = %.2f M rows/s", label, count, best, Double(count) / best / 1e6))
    }

    @Test("fused decode throughput over a raw wire body (parse + build split)")
    func fusedDecodeThroughput() throws {
        let count = 1_000_000
        let body = Self.buildFusedBody(count: count)
        let block = ClickHouseBlock(
            rowCount: count, columnCount: 3,
            columnNames: ["id", "name", "value"], columnTypes: ["UInt64", "String", "Float64"],
            bodyStart: 0, bodyLength: body.count
        )
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            // Replicate the column layout the parse computes, untimed, so we can
            // time the build alone and a raw-pointer build ceiling.
            let idOffset = 0
            let stringStart = count * 8
            var ranges = [Range<Int>](); ranges.reserveCapacity(count)
            var cursor = stringStart
            for _ in 0..<count {
                var length = 0; var shift = 0
                while true {
                    let byte = base.load(fromByteOffset: cursor, as: UInt8.self); cursor += 1
                    length |= Int(byte & 0x7F) << shift
                    if byte < 0x80 { break }
                    shift += 7
                }
                ranges.append(cursor..<(cursor + length)); cursor += length
            }
            let valueOffset = cursor
            var nameSpans = [Int](); nameSpans.reserveCapacity(count * 2)
            for r in ranges { nameSpans.append(r.lowerBound); nameSpans.append(r.count) }
            let prebuilt = ClickHouseRawBlock(
                base: base,
                columnBaseOffset: [idOffset, 0, valueOffset],
                stringSpans: nameSpans,
                stringFieldBase: [-1, 0, -1],
                count: count
            )

            Self.bench("FUSED-FULL", count: count) {
                (try? ClickHouseCodableDecoder.decodeFusedRows(type: FusedRow.self, block: block, body: raw))?.count ?? 0
            }
            Self.bench("FUSED-BUILD", count: count) {
                (try? FusedRow.decodeFused(prebuilt))?.count ?? 0
            }
            Self.bench("FUSED-BUILD-NOSTR", count: count) {
                var rows = [FusedRowNoStr](); rows.reserveCapacity(count)
                for i in 0..<count { rows.append(FusedRowNoStr(id: prebuilt.uint64(0, i), value: prebuilt.double(2, i))) }
                return rows.count
            }
            Self.bench("FUSED-RAW-VALIDATED", count: count) {
                var rows = [FusedRow](); rows.reserveCapacity(count)
                for i in 0..<count {
                    let r = ranges[i]
                    let name = String(decoding: UnsafeRawBufferPointer(start: base + r.lowerBound, count: r.count), as: UTF8.self)
                    rows.append(FusedRow(
                        id: base.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self),
                        name: name,
                        value: base.loadUnaligned(fromByteOffset: valueOffset + i * 8, as: Double.self)
                    ))
                }
                return rows.count
            }
            Self.bench("FUSED-RAW-UNCHECKED", count: count) {
                var rows = [FusedRow](); rows.reserveCapacity(count)
                for i in 0..<count {
                    let r = ranges[i]
                    let name = String(unsafeUninitializedCapacity: r.count) { buffer in
                        memcpy(buffer.baseAddress!, base + r.lowerBound, r.count); return r.count
                    }
                    rows.append(FusedRow(
                        id: base.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self),
                        name: name,
                        value: base.loadUnaligned(fromByteOffset: valueOffset + i * 8, as: Double.self)
                    ))
                }
                return rows.count
            }
        }
    }

    private struct OneFieldRow: Decodable { let id: UInt64 }

    @Test("decodeRows throughput for a single UInt64 field (per-row vs per-field isolation)")
    func decodeOneField() throws {
        let count = 1_000_000
        var ids: [UInt64] = []; ids.reserveCapacity(count)
        for n in 0..<count { ids.append(UInt64(n)) }
        let columns = [ClickHouseNamedColumn(name: "id", column: .uint64(ids))]
        _ = try ClickHouseCodableDecoder.decodeRows(type: OneFieldRow.self, columns: columns, rowCount: count)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let rows = try ClickHouseCodableDecoder.decodeRows(type: OneFieldRow.self, columns: columns, rowCount: count)
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            #expect(rows.count == count)
        }
        print(String(format: "[DECODE-1F] %d rows in %.3fs = %.2f M rows/s", count, best, Double(count) / best / 1e6))
    }
}
