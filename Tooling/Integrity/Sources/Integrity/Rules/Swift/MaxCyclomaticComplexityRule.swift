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

public struct MaxCyclomaticComplexityRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "MaxCyclomaticComplexity"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid functions whose cyclomatic complexity exceeds 3."

    public static let maxComplexity: Int = 3

    public init(ruleID: String = "S011") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = FunctionVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Cyclomatic complexity of \(finding.kind) is \(finding.complexity); maximum allowed is \(Self.maxComplexity). Extract sub-expressions into named functions.",
                severity: .error
            )
        }
    }
}

private final class FunctionVisitor: SyntaxVisitor {

    struct Finding {
        let kind: String
        let complexity: Int
        let position: AbsolutePosition
    }

    var findings: [Finding] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            evaluate(
                body: body,
                kind: "function '\(node.name.text)'",
                position: node.name.positionAfterSkippingLeadingTrivia
            )
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            evaluate(
                body: body,
                kind: "initializer",
                position: node.initKeyword.positionAfterSkippingLeadingTrivia
            )
        }
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            evaluate(
                body: body,
                kind: "deinitializer",
                position: node.deinitKeyword.positionAfterSkippingLeadingTrivia
            )
        }
        return .visitChildren
    }

    private func evaluate(body: CodeBlockSyntax, kind: String, position: AbsolutePosition) {
        let counter = ComplexityCounter()
        counter.walk(body)
        let complexity = counter.complexity
        if complexity > MaxCyclomaticComplexityRule.maxComplexity {
            findings.append(Finding(kind: kind, complexity: complexity, position: position))
        }
    }
}

private final class ComplexityCounter: SyntaxVisitor {

    var complexity = 1

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        if isDefaultCase(node) {
            return .visitChildren
        }
        if isLeafDispatchCase(node) {
            return .visitChildren
        }
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
        complexity += 1
        return .visitChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if case .binaryOperator(let text) = token.tokenKind, text == "&&" || text == "||" {
            complexity += 1
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    private func isDefaultCase(_ node: SwitchCaseSyntax) -> Bool {
        if case .default = node.label {
            return true
        }
        return false
    }

    private func isLeafDispatchCase(_ node: SwitchCaseSyntax) -> Bool {
        node.statements.count <= 1
    }
}
