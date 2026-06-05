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
import Dispatch
import Foundation
import Synchronization
import Testing

// The negotiated ServerInfo is rewritten every time the connection
// reconnects and re-handshakes. That write happens on whichever thread
// drives the reconnect, while the value is read off that thread — by the
// public serverInfo accessor and by the INSERT path resolving the
// revision before it hops onto the worker. Behind a plain stored property
// those concurrent accesses are a data race (a reader can observe a torn
// String). Behind a mutex they are safe. This test drives a real
// reconnect concurrently with a tight read loop; it passes under
// ThreadSanitizer only when the storage is synchronized.
@Suite("ServerInfo stays consistent when a reconnect rewrites it concurrently")
struct ServerInfoReconnectRaceTests {

    @Test("reading serverInfo while a reconnect rewrites it is race-free", .timeLimit(.minutes(1)))
    func reconnectRewritesServerInfoSafely() throws {
        let server = FakeClickHouseServer()
        // Revision below 54_058 keeps the ServerHello tail empty. The first
        // connection handshakes then closes; the second (the reconnect)
        // handshakes again, rewriting ServerInfo.
        server.runThenAcceptReconnect(serverHello: FakeClickHouseServer.serverHello(revision: 54_057))

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        // Break the connection through the recv path so the socket is closed
        // and the next send drives a reconnect.
        _ = try? connection.receiveScalarUInt64()

        // Reader: hammer the off-worker accessor (touching the String field)
        // continuously, so it is guaranteed to be running when the reconnect
        // rewrites ServerInfo on this thread.
        let stop = Atomic<Bool>(false)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while !stop.load(ordering: .relaxed) {
                _ = connection.serverInfo.name
            }
            readerDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        // Drive the reconnect: the send finds a closed socket, re-handshakes
        // (rewriting ServerInfo), and replays the query on the fresh socket.
        var threw = false
        do {
            try connection.sendQuery("SELECT 1")
        } catch {
            threw = true
        }

        stop.store(true, ordering: .relaxed)
        readerDone.wait()
        server.finished.wait()

        #expect(!threw)
        #expect(connection.serverInfo.revision == 54_057)
    }
}
