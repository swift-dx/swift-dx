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

public struct NoTodoCommentRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoTodoComment"
    public let ruleArea: RuleArea = .generic
    public let summary = "Forbid TODO / FIXME / XXX / HACK comments; track deferred work in the issue tracker."

    public init(ruleID: String = "G003") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let pattern = #"//\s*(TODO|FIXME|XXX|HACK)\b"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return []
        }
        var violations: [Violation] = []
        for (zeroIndex, line) in file.lines.enumerated() {
            let lineNumber = zeroIndex + 1
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                violations.append(
                    Violation(
                        file: file.path,
                        line: lineNumber,
                        ruleID: ruleID,
                        ruleName: ruleName,
                        message: "TODO / FIXME / XXX / HACK comments are forbidden. Reference a tracked issue or remove the comment.",
                        severity: .error
                    )
                )
            }
        }
        return violations
    }
}
