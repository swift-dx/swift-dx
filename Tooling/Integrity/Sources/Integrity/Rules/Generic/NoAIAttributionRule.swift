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

public struct NoAIAttributionRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoAIAttribution"
    public let ruleArea: RuleArea = .generic
    public let summary = "Forbid AI-attribution phrases in source (Co-Authored-By: Claude, Anthropic, robot emoji, etc.)."

    private let bannedPhrases: [String] = [
        "Co-Authored-By: Claude",
        "Co-authored-by: Claude",
        "Co-Authored-By: Codex",
        "Co-authored-by: Codex",
        "Generated with Claude Code",
        "Generated with Codex",
        "Anthropic",
        "OpenAI",
        "\u{1F916}",
    ]

    public init(ruleID: String = "G004") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        var violations: [Violation] = []
        for (zeroIndex, line) in file.lines.enumerated() {
            let lineNumber = zeroIndex + 1
            for phrase in bannedPhrases where line.contains(phrase) {
                violations.append(
                    Violation(
                        file: file.path,
                        line: lineNumber,
                        ruleID: ruleID,
                        ruleName: ruleName,
                        message: "AI-attribution phrase is forbidden in source. Found '\(phrase)'.",
                        severity: .error
                    )
                )
            }
        }
        return violations
    }
}
