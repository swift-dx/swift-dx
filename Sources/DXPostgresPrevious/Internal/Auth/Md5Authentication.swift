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

import Crypto
import DXCore

// PostgreSQL's legacy MD5 password scheme. The token sent to the server is
// "md5" followed by the hex MD5 of (the hex MD5 of password+username) salted
// with the four random bytes from the AuthenticationMD5Password message. MD5 is
// cryptographically broken; this exists only to interoperate with servers still
// configured for `md5` authentication. New deployments should use SCRAM-SHA-256.
enum Md5Authentication {

    static func token(username: String, password: String, salt: [UInt8]) -> [UInt8] {
        let inner = hexDigest(of: Array(password.utf8) + Array(username.utf8))
        let outer = hexDigest(of: Array(inner.utf8) + salt)
        return Array("md5\(outer)".utf8)
    }

    private static func hexDigest(of bytes: [UInt8]) -> String {
        Hex.encodeLower(Array(Insecure.MD5.hash(data: bytes)))
    }
}
