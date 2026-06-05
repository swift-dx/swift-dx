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

// The reconnect loop retries transient failures (connection refused, a
// dropped socket) until the broker returns. But a server that answers the
// reconnect handshake with an exception — authentication failed, unknown
// database, access denied — is actively refusing this client; retrying
// cannot succeed. Under the default unbounded always-retry policy the loop
// would otherwise spin forever on a permanent rejection, wedging the
// connection. The reconnect must fail fast and surface the server
// exception instead.
@Suite("reconnect fails fast when the server rejects the handshake")
struct ReconnectHandshakeRejectionTests {

    private static func authExceptionPacket() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(2, into: &bytes)             // packet type: Exception
        ClickHouseWire.writeFixedInt(Int32(516), into: &bytes)   // code: AUTHENTICATION_FAILED
        ClickHouseWire.writeString("Authentication failed", into: &bytes)
        ClickHouseWire.writeString("password is incorrect", into: &bytes)
        ClickHouseWire.writeString("", into: &bytes)             // stack trace
        bytes.append(0)                                          // has nested
        return bytes
    }

    @Test("a reconnect whose handshake is rejected by the server fails fast, not forever", .timeLimit(.minutes(1)))
    func reconnectRejectionFailsFast() async throws {
        let server = FakeClickHouseServer()
        server.runThenRejectReconnect(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            // A lone Data marker then a close: the first operation reads the
            // marker, hits EOF on the block body, and tears the socket down
            // (a recv failure does not reconnect), so the NEXT operation is
            // the one that reconnects.
            firstConnectionScript: [.drainRequest, .reply([0x01])],
            reconnectReply: Self.authExceptionPacket()
        )

        let client = try await ClickHouseClient(host: "127.0.0.1", port: server.port)

        // Operation 1 breaks the connection and closes the socket.
        _ = try? await client.execute("SELECT 1", timeout: .seconds(5))

        // Operation 2 reconnects; the handshake is rejected. With the fix
        // this surfaces the server exception quickly; without it the
        // always-retry loop spins until the test's time limit.
        var caught: ClickHouseError = .reconnectExhausted(attempts: -1)
        var threw = false
        do {
            try await client.execute("SELECT 1", timeout: .seconds(5))
        } catch {
            caught = error
            threw = true
        }
        await client.close()
        server.finished.wait()

        #expect(threw)
        guard case .queryFailed(let exception) = caught else {
            Issue.record("expected queryFailed surfacing the server rejection, got \(caught)")
            return
        }
        #expect(exception.code == 516)
    }
}
