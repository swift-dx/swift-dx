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
import NIOCore
import Testing

@Suite("Query packet wire bytes — capture for comparison vs real-server probe")
struct ClickHouseQueryPacketWireBytesTest {

    @Test("dump query packet bytes for SELECT 1 at revision 54_479")
    func dumpSelectOneAtRev54479() throws {
        var info = ClickHouseClientInfo()
        info.queryKind = .initialQuery
        info.initialUser = ""
        info.initialQueryID = ""
        info.initialAddress = "[::]:0"
        info.initialQueryStartTimeMicroseconds = 0
        info.clientInterface = .tcp
        info.osUser = ""
        info.clientHostname = ""
        info.clientName = "SwiftDX Probe"
        info.clientVersionMajor = 1
        info.clientVersionMinor = 0
        info.clientRevision = 54_479
        info.quotaKey = ""
        info.distributedDepth = 0
        info.clientVersionPatch = 0
        info.collaborateWithInitiator = 0
        info.countParticipatingReplicas = 0
        info.numberOfCurrentReplica = 0

        let packet = ClickHouseQueryPacket(
            queryID: "q-1",
            clientInfo: info,
            settings: [],
            interserverSecret: "",
            queryProcessingStage: .complete,
            compression: false,
            queryText: "SELECT 1",
            parameters: []
        )

        var buffer = ByteBuffer()
        // The full wire prefix the encoder produces: packet type + body
        ClickHouseClientPacketType.query.write(into: &buffer)
        try packet.encode(into: &buffer, revision: 54_479)

        let bytes = Array(buffer.readableBytesView)
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: "")
        print("[DUMP] swift-sdk query packet \(bytes.count) bytes:")
        print("[DUMP] \(hex)")
        // Always passes — purely for output capture
        #expect(bytes.count > 0)
    }

}
