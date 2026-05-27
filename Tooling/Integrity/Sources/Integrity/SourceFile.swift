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

import Foundation
import SwiftSyntax
import SwiftParser

// Safe across threads because every stored property is immutable after init
// and SwiftSyntax's SourceFileSyntax and SourceLocationConverter are
// thread-safe for concurrent read access (they expose no mutation API).
public struct SourceFile: @unchecked Sendable {

    public let path: String
    public let contents: String
    public let lines: [String]
    public let syntaxTree: SourceFileSyntax
    public let locationConverter: SourceLocationConverter

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
        self.lines = contents.components(separatedBy: "\n")
        let parsed = Parser.parse(source: contents)
        self.syntaxTree = parsed
        self.locationConverter = SourceLocationConverter(fileName: path, tree: parsed)
    }

    public func lineNumber(of position: AbsolutePosition) -> Int {
        let location = locationConverter.location(for: position)
        return location.line
    }
}
