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

// The post-Hello Addendum carries the send/recv chunked-framing strings
// only from protocol revision 54470 (DBMS_MIN_PROTOCOL_VERSION_WITH_
// CHUNKED_PACKETS, ClickHouse 24.x). A server that negotiates an older
// revision - the 23.x line is still widely deployed - reads an Addendum
// without those two strings. If the client sends them anyway, the server
// reads "notchunked" as the start of the following Query packet and the
// connection desyncs, so the client cannot talk to any pre-24.x server.
// The Addendum must be gated on the negotiated revision.
@Suite("the post-Hello Addendum is gated on the negotiated server revision")
struct PreChunkedAddendumGatingTests {

    static let preChunkedRevision: UInt64 = 54_465

    @Test("a pre-chunked server is not sent the chunked-framing strings", .timeLimit(.minutes(1)))
    func gatesChunkedStringsForOlderServer() throws {
        let server = FakeClickHouseServer()
        server.captureHandshakeAddendum(
            serverHello: FakeClickHouseServer.serverHello(revision: Self.preChunkedRevision)
        )

        let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        connection.close()
        server.finished.wait()

        let addendum = server.capturedRequests[0]
        #expect(!Self.contains(addendum, subsequence: Array("notchunked".utf8)))
        #expect(addendum == [0x00, 0x00])
    }

    private static func contains(_ haystack: [UInt8], subsequence needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
