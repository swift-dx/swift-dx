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

@Suite struct BlockingConnectionCloseTests {

    @Test func closeIsIdempotentAndLeavesAReusedDescriptorIntact() {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        close(descriptors[1])

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        connection.close()

        var reused: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &reused) == 0)
        #expect(dup2(reused[0], descriptors[0]) == descriptors[0])

        connection.close()

        #expect(fcntl(descriptors[0], F_GETFD) != -1)

        close(descriptors[0])
        close(reused[0])
        close(reused[1])
    }
}
