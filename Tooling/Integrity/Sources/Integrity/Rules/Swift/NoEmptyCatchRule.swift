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

public struct NoEmptyCatchRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoEmptyCatch"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid empty catch blocks; if you catch, you handle."

    public init(ruleID: String = "S009") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = EmptyCatchVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { position in
            Violation(
                file: file.path,
                line: file.lineNumber(of: position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Empty catch block forbidden. Log, rethrow, or update observable state. Otherwise remove the do/catch and let the error propagate.",
                severity: .error
            )
        }
    }
}

private final class EmptyCatchVisitor: SyntaxVisitor {

    var findings: [AbsolutePosition] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        if node.body.statements.isEmpty {
            findings.append(node.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }
}
