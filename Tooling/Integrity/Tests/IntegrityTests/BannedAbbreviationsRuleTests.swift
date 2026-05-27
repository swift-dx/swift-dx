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
struct BannedAbbreviationsRuleTests {

    private func makeRule() -> BannedAbbreviationsRule {
        BannedAbbreviationsRule()
    }

    @Test
    func flagsBareIdentifier() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let cfg = 1\n")
        let violations = makeRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].line == 1)
        #expect(violations[0].message.contains("cfg"))
    }

    @Test
    func ignoresIdentifierInsideLineComment() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "// cfg here\n")
        #expect(makeRule().check(file).isEmpty)
    }

    @Test
    func ignoresIdentifierInsidePlainStringLiteral() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let label = \"cfg here\"\n")
        #expect(makeRule().check(file).isEmpty)
    }

    @Test
    func ignoresIdentifierInsideStringLiteralWithEscapedQuotes() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let key: [UInt8] = Array(\"\\\"seq\\\":\".utf8)\n"
        )
        let violations = makeRule().check(file)
        #expect(violations.isEmpty, "expected no violation; got \(violations.map(\.message))")
    }

    @Test
    func ignoresIdentifierInsideRawStringLiteral() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "let path = #\"cfg/path\"#\n"
        )
        #expect(makeRule().check(file).isEmpty)
    }

    @Test
    func ignoresIdentifierInsideMultiLineString() {
        let contents = """
        let block = \"\"\"
        cfg in the middle
        seq as a word
        \"\"\"
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(makeRule().check(file).isEmpty)
    }

    @Test
    func flagsIdentifierInsideStringInterpolation() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let cfg = 1\nprint(\"\\(cfg)\")\n")
        let violations = makeRule().check(file)
        #expect(violations.count >= 2, "expected violations on declaration and on interpolation reference")
    }

    @Test
    func doesNotFlagPartialIdentifierMatch() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let configValue = 1\nlet context = 2\n")
        #expect(makeRule().check(file).isEmpty)
    }

    @Test
    func isCaseSensitive() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let Cfg = 1\nlet Ctx = 2\n")
        #expect(makeRule().check(file).isEmpty)
    }

    @Test
    func flagsFunctionParameterName() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "func handle(cfg: Int) {}\n")
        let violations = makeRule().check(file)
        #expect(!violations.isEmpty)
    }

    @Test
    func flagsMemberAccess() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let value = container.cfg\n")
        let violations = makeRule().check(file)
        #expect(violations.contains { $0.message.contains("cfg") })
    }
}
