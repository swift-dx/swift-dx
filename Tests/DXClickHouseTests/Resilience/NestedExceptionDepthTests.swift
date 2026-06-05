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

// A server Exception packet (type 2) carries a chain of exceptions: each
// frame is code/name/message/stack-trace plus a has-nested byte, and a set
// byte means another frame follows. The reader recursed once per frame with
// no depth bound, so a malicious or malfunctioning server could send an
// arbitrarily deep chain (a few bytes per level) and drive the client into
// unbounded recursion until the thread stack overflows and the process
// crashes. The reader must cap the nesting depth and reject an over-deep
// chain with a typed error instead.
@Suite("a deeply nested server-exception chain is rejected, not recursed without bound")
struct NestedExceptionDepthTests {

    private static func exceptionChain(levels: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(2, into: &bytes) // Exception packet
        for index in 0..<levels {
            withUnsafeBytes(of: Int32(0).littleEndian) { bytes.append(contentsOf: $0) } // code
            ClickHouseWire.writeString("", into: &bytes)  // name
            ClickHouseWire.writeString("", into: &bytes)  // message
            ClickHouseWire.writeString("", into: &bytes)  // stack trace
            bytes.append(index < levels - 1 ? 1 : 0)      // has-nested
        }
        return bytes
    }

    @Test("an exception chain deeper than the cap is rejected with a typed error", .timeLimit(.minutes(1)))
    func rejectsOverDeepChain() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .reply(Self.exceptionChain(levels: 200))]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT 1")
        var stage = "none"
        var rejected = false
        do {
            _ = try connection.receiveBlocks { _, _ in }
        } catch {
            if case .protocolError(let parsed, let message) = error {
                stage = parsed
                rejected = message.contains("exceeds 128 levels")
            }
        }
        server.finished.wait()

        #expect(stage == "exception")
        #expect(rejected)
    }
}
