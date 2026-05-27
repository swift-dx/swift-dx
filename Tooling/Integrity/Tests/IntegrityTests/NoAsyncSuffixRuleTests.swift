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
struct NoAsyncSuffixRuleTests {

    @Test
    func flagsAsyncFunctionWithAsyncSuffix() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "func fetchAsync() async {}\n")
        let violations = NoAsyncSuffixRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsAsyncThrowsFunctionWithAsyncSuffix() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "func loadAsync() async throws -> Data { Data() }\n"
        )
        let violations = NoAsyncSuffixRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagNonAsyncFunctionEndingInAsync() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "func publishBatchAsync() -> Int { 0 }\n"
        )
        #expect(NoAsyncSuffixRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagAsyncFunctionWithoutAsyncSuffix() {
        let file = SourceFile(
            path: "/tmp/Sample.swift",
            contents: "func fetch() async {}\n"
        )
        #expect(NoAsyncSuffixRule().check(file).isEmpty)
    }
}
