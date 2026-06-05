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

// The most common authentication scenario is a wrong password on the very
// first connect, not on a reconnect. The server answers the handshake with an
// Exception (AUTHENTICATION_FAILED) instead of a Hello. The client must
// surface that exception verbatim — code and message — so an operator sees
// "authentication failed", not a generic "connection failed" that hides the
// real cause.
@Suite("an initial-connect handshake rejection surfaces the server auth exception")
struct InitialConnectAuthFailureTests {

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

    @Test("connecting to a server that rejects the handshake throws the server exception", .timeLimit(.minutes(1)))
    func initialConnectRejectionSurfacesException() async throws {
        let server = FakeClickHouseServer()
        server.run(serverHello: Self.authExceptionPacket(), script: [])
        defer { server.stop() }

        var caught: ClickHouseError = .reconnectExhausted(attempts: -1)
        var threw = false
        do {
            _ = try await ClickHouseClient(host: "127.0.0.1", port: server.port)
        } catch {
            caught = error
            threw = true
        }

        #expect(threw)
        guard case .queryFailed(let exception) = caught else {
            Issue.record("expected queryFailed surfacing the server auth rejection, got \(caught)")
            return
        }
        #expect(exception.code == 516)
        #expect(exception.name == "Authentication failed")
        #expect(exception.message == "password is incorrect")
    }
}
