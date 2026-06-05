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

    @Test func tokenMatchesKnownAnswerVector() {
        let token = Md5Authentication.token(username: "postgres", password: "secret", salt: [0x01, 0x02, 0x03, 0x04])
        #expect(String(decoding: token, as: UTF8.self) == "md5bb41a296aab6baccb36ff243a562abff")
    }

    @Test func tokenSaltChangesTheDigest() {
        let first = Md5Authentication.token(username: "postgres", password: "secret", salt: [0x01, 0x02, 0x03, 0x04])
        let second = Md5Authentication.token(username: "postgres", password: "secret", salt: [0x04, 0x03, 0x02, 0x01])
        #expect(first != second)
        #expect(String(decoding: first, as: UTF8.self).hasPrefix("md5"))
        #expect(first.count == 35)
    }
}
