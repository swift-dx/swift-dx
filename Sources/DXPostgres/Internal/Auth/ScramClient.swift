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
import Foundation

// Client side of a SCRAM-SHA-256 exchange (RFC 5802 / RFC 7677) without channel
// binding. The GS2 header is the fixed "n,," (no channel binding, no authzid),
// whose base64 encoding "biws" is echoed in the client-final message. PostgreSQL
// carries the authenticated role in the startup packet and passes an empty SCRAM
// username here; the field is a parameter so the exchange can also be exercised
// against the RFC test vectors. The exchange is three steps: client-first out, then
// client-final computed from the server-first, then verification of the
// server-final.
struct ScramClient {

    private let password: [UInt8]
    private let clientNonce: String
    private let clientFirstBare: String
    private var serverSignature: [UInt8]

    init(username: String, password: String, clientNonce: String) {
        self.password = Array(password.utf8)
        self.clientNonce = clientNonce
        self.clientFirstBare = "n=\(Self.escapeUsername(username)),r=\(clientNonce)"
        self.serverSignature = []
    }

    // RFC 5802 reserves ',' and '=' in the username field; they are escaped as
    // =2C and =3D. PostgreSQL sends an empty username (the authenticated role
    // comes from the startup packet), in which case there is nothing to escape.
    private static func escapeUsername(_ username: String) -> String {
        username
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
    }

    func clientFirstMessage() -> [UInt8] {
        Array("n,,\(clientFirstBare)".utf8)
    }

    mutating func clientFinalMessage(serverFirst: [UInt8]) throws(PostgresError) -> [UInt8] {
        let parsed = try ScramServerFirst.parse(serverFirst)
        try verifyServerNonce(parsed.nonce)
        let saltedPassword = PostgresPBKDF2.deriveSHA256(password: password, salt: parsed.salt, iterations: parsed.iterations)
        let clientKey = PostgresPBKDF2.hmacSHA256(key: saltedPassword, message: Array("Client Key".utf8))
        let storedKey = Array(SHA256.hash(data: clientKey))
        let clientFinalWithoutProof = "c=biws,r=\(parsed.nonce)"
        let authMessage = "\(clientFirstBare),\(String(decoding: serverFirst, as: UTF8.self)),\(clientFinalWithoutProof)"
        let authMessageBytes = Array(authMessage.utf8)
        let clientSignature = PostgresPBKDF2.hmacSHA256(key: storedKey, message: authMessageBytes)
        let serverKey = PostgresPBKDF2.hmacSHA256(key: saltedPassword, message: Array("Server Key".utf8))
        serverSignature = PostgresPBKDF2.hmacSHA256(key: serverKey, message: authMessageBytes)
        let proof = Base64.encode(xor(clientKey, clientSignature))
        return Array("\(clientFinalWithoutProof),p=\(proof)".utf8)
    }

    func verifyServerFinal(_ data: [UInt8]) throws(PostgresError) {
        let received = try ScramServerFinal.parseVerifier(data)
        guard received == serverSignature else {
            throw PostgresError.authenticationFailed(reason: "SCRAM server signature did not match; the server may not know the role's password")
        }
    }

    private func verifyServerNonce(_ serverNonce: String) throws(PostgresError) {
        guard serverNonce.hasPrefix(clientNonce) else {
            throw PostgresError.authenticationFailed(reason: "SCRAM server nonce does not extend the client nonce")
        }
    }

    private func xor(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        var result = left
        for index in result.indices {
            result[index] ^= right[index]
        }
        return result
    }
}
