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

public struct NoAsyncSuffixRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoAsyncSuffix"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid 'Async' suffix on functions already declared async; the keyword carries the semantic."

    public init(ruleID: String = "S003") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = AsyncFunctionNameVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Function '\(finding.name)' is declared 'async' and ends in 'Async'. Drop the suffix; the keyword carries the semantic.",
                severity: .error
            )
        }
    }
}

private final class AsyncFunctionNameVisitor: SyntaxVisitor {

    var findings: [(name: String, position: AbsolutePosition)] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let isAsync = node.signature.effectSpecifiers?.asyncSpecifier != nil
        if isAsync, name.hasSuffix("Async"), name != "Async" {
            findings.append((name: name, position: node.name.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }
}
