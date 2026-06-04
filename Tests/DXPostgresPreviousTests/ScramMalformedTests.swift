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

@Suite struct ScramMalformedTests {

    @Test func serverFirstRejectsMissingNonce() {
        #expect(throws: PostgresError.self) {
            try ScramServerFirst.parse(Array("s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8))
        }
    }

    @Test func serverFirstRejectsInvalidSaltBase64() {
        #expect(throws: PostgresError.self) {
            try ScramServerFirst.parse(Array("r=abc,s=!!!notbase64!!!,i=4096".utf8))
        }
    }

    @Test func serverFirstRejectsNonNumericIterations() {
        #expect(throws: PostgresError.self) {
            try ScramServerFirst.parse(Array("r=abc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=lots".utf8))
        }
    }

    @Test func serverFirstParsesWellFormedMessage() throws {
        let parsed = try ScramServerFirst.parse(Array("r=abc123,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8))
        #expect(parsed.nonce == "abc123")
        #expect(parsed.iterations == 4096)
        #expect(!parsed.salt.isEmpty)
    }

    @Test func serverFinalSurfacesServerReportedError() {
        #expect(throws: PostgresError.self) {
            try ScramServerFinal.parseVerifier(Array("e=invalid-proof".utf8))
        }
    }

    @Test func serverFinalRejectsMissingVerifier() {
        #expect(throws: PostgresError.self) {
            try ScramServerFinal.parseVerifier(Array("x=y".utf8))
        }
    }
}
