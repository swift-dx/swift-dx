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

// A Variant column in a skipped Totals/Extremes/Log block carries one
// discriminator byte per row selecting the active member (255 = NULL).
// The skip counts present rows per member by indexing a per-member array
// with the discriminator. A discriminator past the member count would
// crash the unchecked array subscript; the skip must reject it.
@Suite("Variant skip rejects an out-of-range discriminator instead of trapping")
struct VariantSkipDiscriminatorTests {

    private static func uint64LE(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func totalsBlockWithBadDiscriminator() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(7, into: &bytes)             // packet type: Totals
        ClickHouseWire.writeString("", into: &bytes)            // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)            // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)            // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)            // row count
        ClickHouseWire.writeString("v", into: &bytes)           // column name
        ClickHouseWire.writeString("Variant(UInt8)", into: &bytes) // column type (1 member)
        bytes.append(0)                                         // custom serialization flag
        bytes.append(contentsOf: uint64LE(0))                   // basic-discriminators mode prefix
        bytes.append(5)                                         // row 0 discriminator (>= 1 member, != 255)
        return bytes
    }

    @Test("a Variant discriminator past the member count is rejected in the skip path", .timeLimit(.minutes(1)))
    func rejectsOutOfRangeDiscriminator() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.totalsBlockWithBadDiscriminator())]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT 1")
        var stage = "none"
        do {
            _ = try connection.receiveBlocks { _, _ in }
        } catch {
            if case .protocolError(let parsed, _) = error {
                stage = parsed
            }
        }
        server.finished.wait()

        #expect(stage == "decoder.variant")
    }
}
