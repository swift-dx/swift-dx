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

import Testing
import Glibc
@testable import DXPostgres

@Suite struct PostgresListenerLifecycleTests {

    @Test(.timeLimit(.minutes(1)))
    func droppingAListenerClosesItsConnection() {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let readyForQuery: [UInt8] = [0x5A, 0x00, 0x00, 0x00, 0x05, 0x49]
        readyForQuery.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        openListenerAndDrop(descriptors[0])

        var closed = false
        for _ in 0..<2000 {
            if fcntl(descriptors[0], F_GETFD) == -1 { closed = true; break }
            usleep(1000)
        }
        #expect(closed)
    }

    private func openListenerAndDrop(_ descriptor: Int32) {
        let connection = BlockingPostgresConnection(descriptor: descriptor)
        _ = try? PostgresListener(connection: connection, channels: ["ch"])
    }
}
