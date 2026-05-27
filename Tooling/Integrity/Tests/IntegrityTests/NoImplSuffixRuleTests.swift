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
struct NoImplSuffixRuleTests {

    @Test
    func flagsPublicClassImpl() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "public class FooImpl {}\n")
        let violations = NoImplSuffixRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsPublicStructImpl() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "public struct BarImpl {}\n")
        let violations = NoImplSuffixRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsPublicActorImpl() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "public actor StoreImpl {}\n")
        let violations = NoImplSuffixRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsOpenClassImpl() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "open class BaseImpl {}\n")
        let violations = NoImplSuffixRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagInternalImpl() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "final class FooImpl {}\n")
        #expect(NoImplSuffixRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagPublicTypeWithoutImplSuffix() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "public struct Foo {}\n")
        #expect(NoImplSuffixRule().check(file).isEmpty)
    }
}
