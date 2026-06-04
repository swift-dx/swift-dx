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

@testable import DXPostgresPrevious

// The vectors are the worked SCRAM-SHA-256 example from RFC 7677 §3 (username
// "user", password "pencil", fixed client nonce). Pinning the client nonce lets
// the whole exchange — client-first framing, salted-password derivation, client
// proof, and server-signature verification — be checked against known-good bytes.
@Suite struct ScramClientTests {

    private static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
    private static let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private static let expectedClientFinal = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
    private static let serverFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    @Test func clientFirstMessageMatchesVector() {
        let client = ScramClient(username: "user", password: "pencil", clientNonce: Self.clientNonce)
        #expect(String(decoding: client.clientFirstMessage(), as: UTF8.self) == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
    }

    @Test func emptyUsernameProducesPostgresStyleClientFirst() {
        let client = ScramClient(username: "", password: "pencil", clientNonce: Self.clientNonce)
        #expect(String(decoding: client.clientFirstMessage(), as: UTF8.self) == "n,,n=,r=rOprNGfwEbeRWgbNEkqO")
    }

    @Test func clientFinalMessageMatchesVector() throws {
        var client = ScramClient(username: "user", password: "pencil", clientNonce: Self.clientNonce)
        let final = try client.clientFinalMessage(serverFirst: Array(Self.serverFirst.utf8))
        #expect(String(decoding: final, as: UTF8.self) == Self.expectedClientFinal)
    }

    @Test func verifyServerFinalAcceptsMatchingSignature() throws {
        var client = ScramClient(username: "user", password: "pencil", clientNonce: Self.clientNonce)
        _ = try client.clientFinalMessage(serverFirst: Array(Self.serverFirst.utf8))
        try client.verifyServerFinal(Array(Self.serverFinal.utf8))
    }

    @Test func verifyServerFinalRejectsTamperedSignature() throws {
        var client = ScramClient(username: "user", password: "pencil", clientNonce: Self.clientNonce)
        _ = try client.clientFinalMessage(serverFirst: Array(Self.serverFirst.utf8))
        #expect(throws: PostgresError.self) {
            try client.verifyServerFinal(Array("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".utf8))
        }
    }

    @Test func clientFinalMessageRejectsNonceThatDoesNotExtendClientNonce() {
        var client = ScramClient(username: "user", password: "pencil", clientNonce: Self.clientNonce)
        let badServerFirst = "r=differentNonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        #expect(throws: PostgresError.self) {
            try client.clientFinalMessage(serverFirst: Array(badServerFirst.utf8))
        }
    }

    @Test func wrongPasswordProducesDifferentProof() throws {
        var client = ScramClient(username: "user", password: "notpencil", clientNonce: Self.clientNonce)
        let final = try client.clientFinalMessage(serverFirst: Array(Self.serverFirst.utf8))
        #expect(String(decoding: final, as: UTF8.self) != Self.expectedClientFinal)
    }
}
