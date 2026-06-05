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

@Suite struct ScramServerMessageTests {

    private let salt = "W22ZaJ0SNY7soEsUEjb6gQ=="

    @Test func attributesSplitOnFirstEqualsPreservingBase64Padding() {
        let parsed = ScramAttributes.parse("r=abc,s=\(salt),i=4096")
        #expect(parsed["r"] == "abc")
        #expect(parsed["s"] == salt)
        #expect(parsed["i"] == "4096")
    }

    @Test func attributesSkipTokensWithoutEquals() {
        let parsed = ScramAttributes.parse("r=abc,garbage,i=1")
        #expect(parsed.count == 2)
        #expect(parsed["r"] == "abc")
        #expect(parsed["i"] == "1")
    }

    @Test func serverFirstParsesAValidMessage() throws {
        let parsed = try ScramServerFirst.parse(Array("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2,s=\(salt),i=4096".utf8))
        #expect(parsed.iterations == 4096)
        #expect(parsed.nonce.hasPrefix("rOprNGfwEbeRWgbNEkqO"))
        #expect(parsed.salt.count == 16)
    }

    @Test func serverFirstRejectsMissingAttributes() {
        #expect(throws: PostgresError.self) { _ = try ScramServerFirst.parse(Array("s=\(salt),i=4096".utf8)) }
        #expect(throws: PostgresError.self) { _ = try ScramServerFirst.parse(Array("r=abc,i=4096".utf8)) }
        #expect(throws: PostgresError.self) { _ = try ScramServerFirst.parse(Array("r=abc,s=\(salt)".utf8)) }
    }

    @Test func serverFirstRejectsMalformedSaltAndIterations() {
        #expect(throws: PostgresError.self) { _ = try ScramServerFirst.parse(Array("r=abc,s=*not base64*,i=4096".utf8)) }
        #expect(throws: PostgresError.self) { _ = try ScramServerFirst.parse(Array("r=abc,s=\(salt),i=0".utf8)) }
        #expect(throws: PostgresError.self) { _ = try ScramServerFirst.parse(Array("r=abc,s=\(salt),i=notanumber".utf8)) }
    }

    @Test func serverFinalSurfacesErrorsAndRejectsMissingOrBadVerifier() {
        #expect(throws: PostgresError.self) { _ = try ScramServerFinal.parseVerifier(Array("e=invalid-proof".utf8)) }
        #expect(throws: PostgresError.self) { _ = try ScramServerFinal.parseVerifier(Array("x=nothing".utf8)) }
        #expect(throws: PostgresError.self) { _ = try ScramServerFinal.parseVerifier(Array("v=*not base64*".utf8)) }
    }

    @Test func serverFinalDecodesAValidVerifier() throws {
        let verifier = try ScramServerFinal.parseVerifier(Array("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=".utf8))
        #expect(verifier.count == 32)
    }
}
