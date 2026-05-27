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
struct NoSingletonRuleTests {

    @Test
    func flagsStaticLetShared() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "final class Logger { static let shared = Logger() }\n"
        )
        let violations = NoSingletonRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("shared"))
    }

    @Test
    func flagsStaticVarInstance() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "actor Cache { static var instance: Cache = .init() }\n"
        )
        let violations = NoSingletonRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsStaticLetCurrent() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "struct Theme { static let current = Theme() }\n"
        )
        let violations = NoSingletonRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsBackquotedDefault() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "struct Config { static let `default` = Config() }\n"
        )
        let violations = NoSingletonRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("default"))
    }

    @Test
    func doesNotFlagInstanceProperty() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "final class Logger { let shared = false }\n"
        )
        #expect(NoSingletonRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagStaticPropertyWithDifferentName() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "struct Endpoint { static let defaultPort: Int = 4222 }\n"
        )
        #expect(NoSingletonRule().check(file).isEmpty)
    }

    @Test
    func customNameList() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "struct A { static let myGlobal = A() }\n"
        )
        let rule = NoSingletonRule(names: ["myGlobal"])
        let violations = rule.check(file)
        #expect(violations.count == 1)
    }
}
