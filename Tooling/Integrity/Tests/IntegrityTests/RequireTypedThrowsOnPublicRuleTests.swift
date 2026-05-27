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
struct RequireTypedThrowsOnPublicRuleTests {

    @Test
    func flagsPublicFunctionUntypedThrows() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func parse() throws -> Int { 0 }\n"
        )
        let violations = RequireTypedThrowsOnPublicRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsOpenFunctionUntypedThrows() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "open class C { open func work() throws {} }\n"
        )
        let violations = RequireTypedThrowsOnPublicRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsPublicInitUntypedThrows() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public struct Foo { public init(value: Int) throws { } }\n"
        )
        let violations = RequireTypedThrowsOnPublicRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsPublicAsyncThrowsCombination() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func fetch() async throws -> Int { 0 }\n"
        )
        let violations = RequireTypedThrowsOnPublicRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagPublicTypedThrows() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func parse() throws(MyError) -> Int { 0 }\n"
        )
        #expect(RequireTypedThrowsOnPublicRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagPublicAsyncTypedThrows() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func fetch() async throws(NetworkError) -> Int { 0 }\n"
        )
        #expect(RequireTypedThrowsOnPublicRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagInternalUntypedThrows() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "func parse() throws -> Int { 0 }\n"
        )
        #expect(RequireTypedThrowsOnPublicRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagPublicNonThrowing() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func fetch() -> Int { 0 }\n"
        )
        #expect(RequireTypedThrowsOnPublicRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagPublicRethrows() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func apply<R>(_ body: () throws -> R) rethrows -> R { try body() }\n"
        )
        #expect(RequireTypedThrowsOnPublicRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagPassthroughCombinatorWithUntypedThrowingClosure() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func withResource<R>(_ body: () throws -> R) throws -> R { try body() }\n"
        )
        #expect(RequireTypedThrowsOnPublicRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagAsyncPassthroughCombinator() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "public func withResource<R>(_ body: () async throws -> R) async throws -> R { try await body() }\n"
        )
        #expect(RequireTypedThrowsOnPublicRule().check(file).isEmpty)
    }
}
