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

public struct NoForceUnwrapRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoForceUnwrap"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid force-unwrap on optionals (!), try!, and as!; handle absence explicitly."

    public init(ruleID: String = "S007") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = ForceUnwrapVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Force-unwrap forbidden (\(finding.kind)). Use guard let, if let, ??, or a throwing alternative.",
                severity: .error
            )
        }
    }
}

private final class ForceUnwrapVisitor: SyntaxVisitor {

    struct Finding {
        let kind: String
        let position: AbsolutePosition
    }

    var findings: [Finding] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        findings.append(Finding(kind: "postfix !", position: node.exclamationMark.positionAfterSkippingLeadingTrivia))
        return .visitChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if let mark = node.questionOrExclamationMark, mark.tokenKind == .exclamationMark {
            findings.append(Finding(kind: "try!", position: mark.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        if let mark = node.questionOrExclamationMark, mark.tokenKind == .exclamationMark {
            findings.append(Finding(kind: "as!", position: mark.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }

    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        if let mark = node.questionOrExclamationMark, mark.tokenKind == .exclamationMark {
            findings.append(Finding(kind: "as!", position: mark.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }
}
