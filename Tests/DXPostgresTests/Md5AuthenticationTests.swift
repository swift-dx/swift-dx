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

@testable import DXPostgres

@Suite struct Md5AuthenticationTests {

    // PostgreSQL MD5 auth token: "md5" + md5( md5(password+username) hex + salt ).
    // The expected value was computed independently for password "secret", user
    // "alice", and salt 01 02 03 04.
    @Test func tokenMatchesKnownVector() {
        let token = Md5Authentication.token(username: "alice", password: "secret", salt: [0x01, 0x02, 0x03, 0x04])
        #expect(String(decoding: token, as: UTF8.self) == "md598a0412b9c31436fc53776e863350083")
    }

    @Test func differentSaltProducesDifferentToken() {
        let first = Md5Authentication.token(username: "alice", password: "secret", salt: [0x01, 0x02, 0x03, 0x04])
        let second = Md5Authentication.token(username: "alice", password: "secret", salt: [0x04, 0x03, 0x02, 0x01])
        #expect(first != second)
    }
}
