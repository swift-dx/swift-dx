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

@Suite struct ServerErrorAssemblerTests {

    @Test func assemblesPreferringNonLocalizedSeverityAndCollectsExtras() throws {
        let error = try ServerErrorAssembler.assemble(from: [
            (code: 0x53, value: "ERROR"),
            (code: 0x56, value: "FATAL"),
            (code: 0x43, value: "28P01"),
            (code: 0x4D, value: "password authentication failed"),
            (code: 0x48, value: "check pg_hba.conf"),
        ])
        #expect(error.severity == "FATAL")
        #expect(error.sqlState == "28P01")
        #expect(error.message == "password authentication failed")
        #expect(error.value(of: .hint) == .present("check pg_hba.conf"))
        #expect(error.value(of: .detail) == .absent)
    }

    @Test func fallsBackToLocalizedSeverity() throws {
        let error = try ServerErrorAssembler.assemble(from: [
            (code: 0x53, value: "ERROR"),
            (code: 0x43, value: "22012"),
            (code: 0x4D, value: "division by zero"),
        ])
        #expect(error.severity == "ERROR")
    }

    @Test func rejectsMessagesMissingGuaranteedFields() {
        #expect(throws: PostgresError.self) { _ = try ServerErrorAssembler.assemble(from: [(code: 0x43, value: "22012"), (code: 0x4D, value: "m")]) }
        #expect(throws: PostgresError.self) { _ = try ServerErrorAssembler.assemble(from: [(code: 0x53, value: "ERROR"), (code: 0x4D, value: "m")]) }
        #expect(throws: PostgresError.self) { _ = try ServerErrorAssembler.assemble(from: [(code: 0x53, value: "ERROR"), (code: 0x43, value: "22012")]) }
        #expect(throws: PostgresError.self) { _ = try ServerErrorAssembler.assemble(from: []) }
    }

    @Test func flagsTransientSqlStatesAsRetryable() throws {
        #expect(try assembled(sqlState: "40001").isRetryable)
        #expect(try assembled(sqlState: "40P01").isRetryable)
        #expect(try assembled(sqlState: "22012").isRetryable == false)
    }

    private func assembled(sqlState: String) throws -> PostgresServerError {
        try ServerErrorAssembler.assemble(from: [(code: 0x53, value: "ERROR"), (code: 0x43, value: sqlState), (code: 0x4D, value: "m")])
    }
}
