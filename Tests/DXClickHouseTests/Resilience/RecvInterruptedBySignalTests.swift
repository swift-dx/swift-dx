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
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// A blocking recv()/send() returns -1 with errno EINTR when a signal is
// delivered to the thread while the syscall is parked. EINTR is not a
// connection failure: the socket is healthy and the syscall must be retried.
// Treating it as an I/O error tore the connection down and failed the query
// on any signal (timers, profilers, job-control), so a process that delivers
// signals to the worker thread saw spurious query failures. The recv loop
// must retry across EINTR and complete normally.
@Suite("a signal-interrupted recv is retried, not turned into a connection failure")
struct RecvInterruptedBySignalTests {

    private static func dataRowBlockThenEnd() -> [UInt8] {
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(1, into: &bytes)       // Data packet
        ClickHouseWire.writeString("", into: &bytes)      // table name
        ClickHouseWire.writeUVarInt(0, into: &bytes)      // block info terminator
        ClickHouseWire.writeUVarInt(1, into: &bytes)      // column count
        ClickHouseWire.writeUVarInt(1, into: &bytes)      // row count
        ClickHouseWire.writeString("n", into: &bytes)     // column name
        ClickHouseWire.writeString("UInt8", into: &bytes) // column type
        bytes.append(0)                                   // custom serialization flag
        bytes.append(42)                                  // one UInt8 value
        ClickHouseWire.writeUVarInt(5, into: &bytes)      // EndOfStream
        return bytes
    }

    // Installs a signal handler WITHOUT SA_RESTART so a parked recv()/send()
    // is interrupted (returns EINTR) rather than auto-restarted. glibc's
    // signal() sets SA_RESTART by default, which is why the deprecated
    // siginterrupt() was previously needed; sigaction with sa_flags == 0
    // expresses the same intent through the supported API.
    private static func installInterruptingHandler(_ number: Int32, _ handler: @escaping @convention(c) (Int32) -> Void) {
        var action = sigaction()
        #if canImport(Glibc)
        action.__sigaction_handler = .init(sa_handler: handler)
        #elseif canImport(Darwin)
        action.__sigaction_u = __sigaction_u(__sa_handler: handler)
        #endif
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        sigaction(number, &action, nil)
    }

    @Test("recv parked during a server delay survives repeated signal interruptions", .timeLimit(.minutes(1)))
    func recvSurvivesSignalStorm() throws {
        let noopHandler: @convention(c) (Int32) -> Void = { _ in }
        Self.installInterruptingHandler(SIGUSR1, noopHandler)
        defer { signal(SIGUSR1, SIG_DFL) }

        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, SIGUSR1)
        pthread_sigmask(SIG_UNBLOCK, &unblock, nil)

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: ClickHouseQueryBuilder.revision),
            script: [.drainRequest, .delay(milliseconds: 400), .reply(Self.dataRowBlockThenEnd())]
        )

        nonisolated(unsafe) let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
        defer { connection.close() }

        try connection.sendQuery("SELECT n FROM t")

        let target = pthread_self()
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.06)
            for _ in 0..<15 {
                pthread_kill(target, SIGUSR1)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        let rows = try connection.receiveBlocks { _, _ in }
        server.finished.wait()

        #expect(rows == 1)
    }
}
