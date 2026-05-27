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
struct NoOptionalsRuleTests {

    @Test
    func flagsOptionalSugarInProperty() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "var x: Int?\n")
        let violations = NoOptionalsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsOptionalSugarInFunctionParameter() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "func foo(arg: String?) {}\n")
        let violations = NoOptionalsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsOptionalSugarInReturnType() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "func foo() -> Data? { nil }\n")
        let violations = NoOptionalsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsImplicitlyUnwrappedOptional() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "var x: Int!\n")
        let violations = NoOptionalsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsGenericOptional() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "var x: Optional<Int>\n")
        let violations = NoOptionalsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagTryQuestion() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let value = try? foo()\n")
        #expect(NoOptionalsRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagAsQuestion() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let value = thing as? String\n")
        #expect(NoOptionalsRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagOptionalChaining() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "let value = obj?.property\n")
        #expect(NoOptionalsRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagIfLet() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "if let x = foo() {}\n")
        #expect(NoOptionalsRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagWeakVar() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "final class Box { weak var value: AnyObject? }\n"
        )
        #expect(NoOptionalsRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagOptionalSubscriptReturnType() {
        let contents = """
        struct Lookup {
            subscript(key: String) -> Int? {
                get { nil }
                set { _ = newValue }
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(NoOptionalsRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagOptionalSubscriptParameter() {
        let contents = """
        struct Lookup {
            subscript(key: String?, fallback: Int) -> Int {
                get { fallback }
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(NoOptionalsRule().check(file).isEmpty)
    }

    @Test
    func stillFlagsOptionalInsideSubscriptBody() {
        let contents = """
        struct Lookup {
            subscript(key: String) -> Int {
                get {
                    var cached: Int? = nil
                    return cached ?? 0
                }
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = NoOptionalsRule().check(file)
        #expect(violations.count == 1)
    }
}
