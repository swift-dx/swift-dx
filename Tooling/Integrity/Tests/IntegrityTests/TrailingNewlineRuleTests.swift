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
struct TrailingNewlineRuleTests {

    @Test
    func acceptsFileWithSingleTrailingNewline() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let x = 1\n")
        #expect(TrailingNewlineRule().check(file).isEmpty)
    }

    @Test
    func flagsFileMissingTrailingNewline() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let x = 1")
        let violations = TrailingNewlineRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("does not end with a trailing newline"))
    }

    @Test
    func flagsFileWithMultipleTrailingNewlines() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let x = 1\n\n")
        let violations = TrailingNewlineRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("multiple trailing newlines"))
    }

    @Test
    func flagsEmptyFile() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "")
        let violations = TrailingNewlineRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("empty"))
    }

    @Test
    func acceptsFileWithBlankLineBeforeFinalNewline() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let x = 1\n\nlet y = 2\n")
        #expect(TrailingNewlineRule().check(file).isEmpty)
    }
}
