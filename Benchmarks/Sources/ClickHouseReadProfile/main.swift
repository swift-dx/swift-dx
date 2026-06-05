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

import DXClickHouse
import Foundation

// Read-only profiling harness: repeats selectAllFused over the persistent
// dx_prof table N times so the read path can be isolated for callgrind /
// cachegrind / timing without write or table-setup noise. Row count and
// iteration count come from argv so the same binary serves a 1-iteration
// callgrind run and a multi-iteration timing run.
struct FusedRow: ClickHouseFusedDecodable, Sendable {

    let id: UInt64
    let name: String
    let value: Double

    static let clickHouseColumnNames = ["id", "name", "value"]

    static func decodeFused(_ block: ClickHouseRawBlock) throws(ClickHouseError) -> [FusedRow] {
        var rows = [FusedRow]()
        rows.reserveCapacity(block.count)
        for i in 0..<block.count {
            rows.append(FusedRow(id: block.uint64(0, i), name: block.string(1, i), value: block.double(2, i)))
        }
        return rows
    }
}

let iterations = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 10) : 10
let host = ProcessInfo.processInfo.environment["CH_HOST"] ?? "127.0.0.1"
let port = Int(ProcessInfo.processInfo.environment["CH_PORT"] ?? "9000") ?? 9000
let password = ProcessInfo.processInfo.environment["CH_PASSWORD"] ?? "dxtest"

let client = try await ClickHouseClient(host: host, port: port, user: "default", password: password, database: "default")

func seconds(_ start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

var best = Double.greatestFiniteMagnitude
var checksum: UInt64 = 0
for iteration in 0..<iterations {
    let start = ContinuousClock.now
    let rows = try await client.selectAllFused("SELECT id, name, value FROM dx_prof", as: FusedRow.self)
    let elapsed = seconds(start)
    best = min(best, elapsed)
    var localChecksum: UInt64 = 0
    for row in rows { localChecksum &+= row.id &+ UInt64(row.name.utf8.count) }
    checksum = localChecksum
    if iterations <= 3 || iteration == iterations - 1 {
        FileHandle.standardError.write(Data("[READ] iter \(iteration): \(rows.count) rows in \(String(format: "%.4f", elapsed))s = \(String(format: "%.2f", Double(rows.count) / elapsed / 1e6)) M rows/s\n".utf8))
    }
}
print(String(format: "[READ-BEST] %.4fs = %.2f M rows/s (checksum %llu)", best, 1_000_000.0 / best / 1e6, checksum))
await client.close()
