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
struct ServerSideImportsRuleTests {

    @Test
    func flagsUIKitImport() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "import UIKit\n")
        let violations = ServerSideImportsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsSwiftUIImport() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "import SwiftUI\n")
        let violations = ServerSideImportsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func flagsAppKitImport() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "import AppKit\n")
        let violations = ServerSideImportsRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func doesNotFlagFoundation() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "import Foundation\n")
        #expect(ServerSideImportsRule().check(file).isEmpty)
    }

    @Test
    func doesNotFlagNIOCore() {
        let file = SourceFile(path: "/tmp/Sample.swift", contents: "import NIOCore\n")
        #expect(ServerSideImportsRule().check(file).isEmpty)
    }
}
