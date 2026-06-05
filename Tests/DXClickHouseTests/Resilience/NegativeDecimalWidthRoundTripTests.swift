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

// A Decimal column's byte width follows its precision (Decimal(5,2)=4 bytes,
// Decimal(18,4)=8, Decimal(30,6)=16). On the wire a value is the low `width`
// bytes of its two's-complement; a NEGATIVE value relies on the decoder
// sign-extending those bytes back to the full 256-bit magnitude. Zero-
// extending would turn a negative amount into a large positive one. This
// round-trips negative, positive, and zero through the real wire encode/decode
// at each width.
@Suite("negative Decimals sign-extend correctly across byte widths")
struct NegativeDecimalWidthRoundTripTests {

    private struct Row: Codable, Sendable, Equatable { let d: ClickHouseDecimal }

    private static func roundTrip(_ rows: [Row]) async throws -> [Row] {
        let columns = try ClickHouseRowEncoder().encode(rows)
        var packet = try ClickHouseBlockWriter.encodeDataPacket(columns: columns, revision: ClickHouseQueryBuilder.revision)
        packet[0] = 1
        var eos: [UInt8] = []; ClickHouseWire.writeUVarInt(5, into: &eos)
        let server = FakeClickHouseServer()
        server.run(serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision), script: [.drainRequest, .reply(packet + eos)])
        defer { server.stop() }
        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        let decoded = try await client.selectAll("SELECT d FROM t", as: Row.self)
        await client.close()
        return decoded
    }

    @Test("Decimal(5,2) (4-byte Int32) round-trips negative, positive, zero", .timeLimit(.minutes(1)))
    func width4() async throws {
        let rows = [
            Row(d: ClickHouseDecimal(unscaled: -1234, precision: 5, scale: 2)),
            Row(d: ClickHouseDecimal(unscaled: 4321, precision: 5, scale: 2)),
            Row(d: ClickHouseDecimal(unscaled: 0, precision: 5, scale: 2)),
        ]
        #expect(try await Self.roundTrip(rows) == rows)
    }

    @Test("Decimal(18,4) (8-byte Int64) round-trips negative, positive, zero", .timeLimit(.minutes(1)))
    func width8() async throws {
        let rows = [
            Row(d: ClickHouseDecimal(unscaled: -987654321, precision: 18, scale: 4)),
            Row(d: ClickHouseDecimal(unscaled: 123456789, precision: 18, scale: 4)),
            Row(d: ClickHouseDecimal(unscaled: 0, precision: 18, scale: 4)),
        ]
        #expect(try await Self.roundTrip(rows) == rows)
    }

    @Test("Decimal(30,6) (16-byte Int128) round-trips negative, positive, zero", .timeLimit(.minutes(1)))
    func width16() async throws {
        let rows = [
            Row(d: ClickHouseDecimal(unscaled: -123456789012345, precision: 30, scale: 6)),
            Row(d: ClickHouseDecimal(unscaled: 987654321098765, precision: 30, scale: 6)),
            Row(d: ClickHouseDecimal(unscaled: 0, precision: 30, scale: 6)),
        ]
        #expect(try await Self.roundTrip(rows) == rows)
    }
}
