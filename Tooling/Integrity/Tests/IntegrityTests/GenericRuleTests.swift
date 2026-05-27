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
struct FileHeaderRuleTests {

    @Test
    func flagsFileMissingSpdxIdentifier() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "import Foundation\n")
        let violations = FileHeaderRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func acceptsFileContainingSpdxIdentifier() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "// SPDX-License-Identifier: Apache-2.0\nimport Foundation\n"
        )
        #expect(FileHeaderRule().check(file).isEmpty)
    }
}

@Suite
struct NoMarkCommentRuleTests {

    @Test
    func flagsMarkComment() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "// MARK: - Section\nlet x = 1\n")
        let violations = NoMarkCommentRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagRegularComment() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "// Regular comment\nlet x = 1\n")
        #expect(NoMarkCommentRule().check(file).isEmpty)
    }
}

@Suite
struct NoTodoCommentRuleTests {

    @Test
    func flagsTodoComment() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "// TODO: implement\n")
        let violations = NoTodoCommentRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsFixmeComment() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "// FIXME: broken\n")
        let violations = NoTodoCommentRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagWordInsideIdentifier() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let todoCount = 0\n")
        #expect(NoTodoCommentRule().check(file).isEmpty)
    }
}

@Suite
struct NoAIAttributionRuleTests {

    @Test
    func flagsCoAuthoredByClaude() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "// Co-Authored-By: Claude\n")
        let violations = NoAIAttributionRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsGeneratedWithClaudeCode() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "// Generated with Claude Code\n")
        let violations = NoAIAttributionRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsAnthropicMention() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let s = \"Anthropic\"\n")
        let violations = NoAIAttributionRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagBenignCode() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let value = 42\n")
        #expect(NoAIAttributionRule().check(file).isEmpty)
    }
}
