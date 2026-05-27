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
struct OneTopLevelPublicTypePerFileRuleTests {

    @Test
    func acceptsSinglePublicType() {
        let contents = """
        public struct Foo {
            public let value: Int
        }
        """
        let file = SourceFile(path: "/tmp/Foo.swift", contents: contents)
        #expect(OneTopLevelPublicTypePerFileRule().check(file).isEmpty)
    }

    @Test
    func flagsTwoPublicTypes() {
        let contents = """
        public struct Foo {}
        public struct Bar {}
        """
        let file = SourceFile(path: "/tmp/Foo.swift", contents: contents)
        let violations = OneTopLevelPublicTypePerFileRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("Bar"))
        #expect(violations[0].message.contains("Foo"))
    }

    @Test
    func flagsPublicProtocolAndPublicStruct() {
        let contents = """
        public protocol Foo {}
        public struct FooImpl {}
        """
        let file = SourceFile(path: "/tmp/Foo.swift", contents: contents)
        let violations = OneTopLevelPublicTypePerFileRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func acceptsPublicTypePlusExtensions() {
        let contents = """
        public struct Foo {
            public let value: Int
        }
        extension Foo: Hashable {}
        extension Foo: CustomStringConvertible {
            public var description: String { "\\(value)" }
        }
        """
        let file = SourceFile(path: "/tmp/Foo.swift", contents: contents)
        #expect(OneTopLevelPublicTypePerFileRule().check(file).isEmpty)
    }

    @Test
    func acceptsPublicTypePlusInternalHelpers() {
        let contents = """
        public struct Foo {
            public let value: Int
        }
        struct InternalHelper {}
        fileprivate enum LocalState { case a, b }
        """
        let file = SourceFile(path: "/tmp/Foo.swift", contents: contents)
        #expect(OneTopLevelPublicTypePerFileRule().check(file).isEmpty)
    }

    @Test
    func acceptsNestedPublicTypes() {
        let contents = """
        public struct Outer {
            public struct Inner {}
            public enum InnerEnum { case a, b }
        }
        """
        let file = SourceFile(path: "/tmp/Outer.swift", contents: contents)
        #expect(OneTopLevelPublicTypePerFileRule().check(file).isEmpty)
    }

    @Test
    func flagsThreeTypesReportsTwoViolations() {
        let contents = """
        public struct A {}
        public struct B {}
        public struct C {}
        """
        let file = SourceFile(path: "/tmp/A.swift", contents: contents)
        let violations = OneTopLevelPublicTypePerFileRule().check(file)
        #expect(violations.count == 2)
    }

    @Test
    func acceptsPublicTypeAliasOnlyOnce() {
        let contents = """
        public typealias Bytes = [UInt8]
        """
        let file = SourceFile(path: "/tmp/Bytes.swift", contents: contents)
        #expect(OneTopLevelPublicTypePerFileRule().check(file).isEmpty)
    }

    @Test
    func flagsPublicTypeAliasAfterPublicStruct() {
        let contents = """
        public struct Foo {}
        public typealias Bar = Int
        """
        let file = SourceFile(path: "/tmp/Foo.swift", contents: contents)
        let violations = OneTopLevelPublicTypePerFileRule().check(file)
        #expect(violations.count == 1)
    }
}
