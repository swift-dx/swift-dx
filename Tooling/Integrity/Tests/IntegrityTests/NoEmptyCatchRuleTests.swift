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
struct NoEmptyCatchRuleTests {

    @Test
    func flagsEmptyCatch() {
        let contents = """
        do {
            try work()
        } catch {
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = NoEmptyCatchRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsEmptyCatchWithBoundError() {
        let contents = """
        do {
            try work()
        } catch let error {

        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = NoEmptyCatchRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsEmptyCatchWithTypePattern() {
        let contents = """
        do {
            try work()
        } catch is MyError {
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = NoEmptyCatchRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagCatchWithRethrow() {
        let contents = """
        do {
            try work()
        } catch {
            throw error
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(NoEmptyCatchRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagCatchWithLogging() {
        let contents = """
        do {
            try work()
        } catch {
            logger.error("\\(error)")
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(NoEmptyCatchRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagTryQuestion() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let result = try? work()\n")
        #expect(NoEmptyCatchRule().check(file).isEmpty)
    }

    @Test
    func flagsTwoEmptyCatchesInOneDo() {
        let contents = """
        do {
            try work()
        } catch is FooError {
        } catch is BarError {
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = NoEmptyCatchRule().check(file)
        #expect(violations.count == 2)
    }
}
