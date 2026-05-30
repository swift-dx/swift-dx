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
import NIOPosix
import Testing

@Suite("Outbound compression -> wire byte mapping")
struct ClickHouseOutboundCompressionTests {

    @Test(".uncompressed maps to the wire byte 0x02 the server expects for an uncompressed frame")
    func uncompressedMapsToWireByte() {
        #expect(ClickHouseClient.OutboundCompression.uncompressed.wireMethod == .uncompressed)
        #expect(ClickHouseClient.OutboundCompression.uncompressed.wireMethod.rawValue == 0x02)
    }

    @Test(".lz4 maps to the wire byte 0x82 documented in the ClickHouse protocol reference")
    func lz4MapsToWireByte() {
        #expect(ClickHouseClient.OutboundCompression.lz4.wireMethod == .lz4)
        #expect(ClickHouseClient.OutboundCompression.lz4.wireMethod.rawValue == 0x82)
    }

    @Test("the wire enum still recognises 0x90 as ZSTD so the decoder can reject it with a typed error")
    func wireEnumStillCarriesZstdForDecodeRecognition() {
        // Defensive: even though the public API can't request ZSTD,
        // a server might still emit a 0x90 frame (e.g. via misconfig).
        // The wire enum must round-trip it so the decoder produces a
        // typed error rather than misframing the stream.
        #expect(ClickHouseCompressionMethod(rawValue: 0x90) == .zstd)
    }

    @Test("Configuration stores .lz4 and lowers it to the wire byte 0x82 the connection factory receives")
    func configurationCarriesLZ4() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let configuration = ClickHouseClient.Configuration(
            endpoints: [.init(host: "ch.example.invalid", port: 9000)],
            compression: .lz4,
            eventLoopGroup: group
        )
        #expect(configuration.compression == .lz4)
        #expect(configuration.compression.wireMethod.rawValue == 0x82)
    }

    @Test("Configuration defaults compression to .uncompressed and lowers it to the wire byte 0x02")
    func configurationDefaultsToUncompressed() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let configuration = ClickHouseClient.Configuration(
            endpoints: [.init(host: "ch.example.invalid", port: 9000)],
            eventLoopGroup: group
        )
        #expect(configuration.compression == .uncompressed)
        #expect(configuration.compression.wireMethod.rawValue == 0x02)
    }

}
