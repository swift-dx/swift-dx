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
@testable import Integrity

@Suite
struct NoForceUnwrapRuleTests {

    @Test
    func flagsPostfixForceUnwrap() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let value = optional!\n")
        let violations = NoForceUnwrapRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsForceUnwrapOnFunctionCall() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let result = compute()!\n"
        )
        let violations = NoForceUnwrapRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsForceUnwrapOnSubscript() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let value = dict[key]!\n"
        )
        let violations = NoForceUnwrapRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsForceTry() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let value = try! decoder.decode(Foo.self, from: data)\n"
        )
        let violations = NoForceUnwrapRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsForceCast() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let value = thing as! String\n"
        )
        let violations = NoForceUnwrapRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagOptionalTry() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let value = try? decoder.decode(Foo.self, from: data)\n"
        )
        #expect(NoForceUnwrapRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagOptionalCast() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let value = thing as? String\n"
        )
        #expect(NoForceUnwrapRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagLogicalNot() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let flag = !condition\n"
        )
        #expect(NoForceUnwrapRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagGuardLet() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "guard let value = optional else { return }\n"
        )
        #expect(NoForceUnwrapRule().check(file).isEmpty)
    }
}
