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

import DXCore

// The server-final SCRAM message. On success it carries the verifier ('v'), the
// server's proof that it too knows the salted password; the client compares it
// against its own computed server signature to authenticate the server. On
// failure it carries an error ('e') the client surfaces verbatim.
enum ScramServerFinal {

    static func parseVerifier(_ data: [UInt8]) throws(PostgresError) -> [UInt8] {
        let attributes = ScramAttributes.parse(String(decoding: data, as: UTF8.self))
        if let serverError = attributes["e"] {
            throw PostgresError.authenticationFailed(reason: "SCRAM server reported: \(serverError)")
        }
        guard let verifier = attributes["v"] else {
            throw PostgresError.authenticationFailed(reason: "SCRAM server-final message missing verifier attribute")
        }
        return try decodeVerifier(verifier)
    }

    private static func decodeVerifier(_ text: String) throws(PostgresError) -> [UInt8] {
        do {
            return try Base64.decode(text)
        } catch {
            throw PostgresError.authenticationFailed(reason: "SCRAM server verifier is not valid base64")
        }
    }
}
