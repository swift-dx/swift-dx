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

@Suite struct ScramClientTests {

    private let clientNonce = "rOprNGfwEbeRWgbNEkqO"
    private let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private let expectedClientFinal = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
    private let serverFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    @Test func matchesRFC7677TestVector() throws {
        var client = ScramClient(username: "user", password: "pencil", clientNonce: clientNonce)
        #expect(String(decoding: client.clientFirstMessage(), as: UTF8.self) == "n,,n=user,r=\(clientNonce)")
        let clientFinal = try client.clientFinalMessage(serverFirst: Array(serverFirst.utf8))
        #expect(String(decoding: clientFinal, as: UTF8.self) == expectedClientFinal)
        try client.verifyServerFinal(Array(serverFinal.utf8))
    }

    @Test func rejectsTamperedServerSignature() throws {
        var client = ScramClient(username: "user", password: "pencil", clientNonce: clientNonce)
        _ = try client.clientFinalMessage(serverFirst: Array(serverFirst.utf8))
        #expect(throws: PostgresError.self) {
            try client.verifyServerFinal(Array("v=7rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=".utf8))
        }
    }

    @Test func rejectsServerNonceNotExtendingClientNonce() throws {
        var client = ScramClient(username: "user", password: "pencil", clientNonce: clientNonce)
        #expect(throws: PostgresError.self) {
            _ = try client.clientFinalMessage(serverFirst: Array("r=SOMEOTHERNONCE,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8))
        }
    }
}
