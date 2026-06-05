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
import Testing

// A Dynamic column's binary prefix declares how many member types follow
// as a server-supplied UVarInt. Converting it to Int unchecked would trap
// (and crash the whole client) on a value exceeding Int, which a corrupt
// or hostile server can send in one field. The decode must reject it as
// malformed instead.
@Suite("Dynamic column rejects an out-of-range member count instead of trapping")
struct DynamicColumnOverflowTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func parseStage(block: ClickHouseBlock, body: [UInt8]) -> String {
        do {
            _ = try body.withUnsafeBytes { raw in
                try ClickHouseCodableDecoder.parseTypedColumns(block: block, body: raw)
            }
            return "none"
        } catch {
            if let typed = error as? ClickHouseError, case .protocolError(let stage, _) = typed { return stage }
            return "other: \(error)"
        }
    }

    @Test("a Dynamic prefix member count above Int.max is rejected, not trapped")
    func rejectsOversizedMemberCount() {
        // 8-byte structure version (0, so no max-types field), then a member
        // count UVarInt of UInt64.max.
        var body = Self.uint64LE(0)
        ClickHouseWire.writeUVarInt(UInt64.max, into: &body)
        let block = ClickHouseBlock(
            rowCount: 1, columnCount: 1,
            columnNames: ["d"],
            columnTypes: ["Dynamic"],
            bodyStart: 0, bodyLength: body.count
        )
        #expect(Self.parseStage(block: block, body: body) == "decoder.parseDynamic")
    }
}
