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

public struct TrailingNewlineRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "TrailingNewline"
    public let ruleArea: RuleArea = .generic
    public let summary = "Require every source file to end with exactly one trailing newline."

    public init(ruleID: String = "G005") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let contents = file.contents
        if contents.isEmpty {
            return [violation(at: 1, message: "File is empty.", path: file.path)]
        }
        if !contents.hasSuffix("\n") {
            return [
                violation(
                    at: max(file.lines.count, 1),
                    message: "File does not end with a trailing newline.",
                    path: file.path
                )
            ]
        }
        if contents.hasSuffix("\n\n") {
            return [
                violation(
                    at: max(file.lines.count, 1),
                    message: "File ends with multiple trailing newlines; keep exactly one.",
                    path: file.path
                )
            ]
        }
        return []
    }

    private func violation(at line: Int, message: String, path: String) -> Violation {
        Violation(
            file: path,
            line: line,
            ruleID: ruleID,
            ruleName: ruleName,
            message: message,
            severity: .error
        )
    }
}
