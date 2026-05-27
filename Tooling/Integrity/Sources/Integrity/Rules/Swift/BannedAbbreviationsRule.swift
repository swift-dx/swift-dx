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

import SwiftSyntax

public struct BannedAbbreviationsRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "BannedAbbreviations"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid identifier abbreviations from the canonical banned list. Write the full word."

    public static let canonicalBanned: Set<String> = [
        "cfg",
        "msg",
        "idx",
        "seq",
        "ptr",
        "info",
        "opts",
        "params",
        "args",
        "desc",
        "temp",
        "tmp",
        "auth",
        "addr",
        "req",
        "resp",
        "ctx",
        "mgr",
        "Manager",
    ]

    public init(ruleID: String = "S001") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = BannedIdentifierVisitor(banned: Self.canonicalBanned)
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Banned abbreviation. Write the full word. Found '\(finding.text)'.",
                severity: .error
            )
        }
    }
}

private final class BannedIdentifierVisitor: SyntaxVisitor {

    let banned: Set<String>
    var findings: [(text: String, position: AbsolutePosition)] = []

    init(banned: Set<String>) {
        self.banned = banned
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if case .identifier(let text) = token.tokenKind, banned.contains(text) {
            findings.append((text: text, position: token.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }
}
