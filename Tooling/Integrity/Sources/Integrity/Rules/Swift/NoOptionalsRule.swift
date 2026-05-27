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

public struct NoOptionalsRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoOptionals"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid Optional types (T?, T!, Optional<T>); weak var is exempt by Swift language constraint."

    public init(ruleID: String = "S002") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = OptionalTypeVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Optional types are forbidden. Use a typed enum, throw at the boundary, or return an empty collection. Found '\(finding.snippet)'.",
                severity: .error
            )
        }
    }
}

private final class OptionalTypeVisitor: SyntaxVisitor {

    var findings: [(snippet: String, position: AbsolutePosition)] = []
    private var insideWeakVarDecl = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isWeak = node.modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.weak)
        }
        if isWeak {
            insideWeakVarDecl = true
        }
        return .visitChildren
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        let isWeak = node.modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.weak)
        }
        if isWeak {
            insideWeakVarDecl = false
        }
    }

    override func visit(_ node: OptionalTypeSyntax) -> SyntaxVisitorContinueKind {
        if insideWeakVarDecl { return .visitChildren }
        let snippet = trimmedDescription(node)
        findings.append((snippet: snippet, position: node.positionAfterSkippingLeadingTrivia))
        return .visitChildren
    }

    override func visit(_ node: ImplicitlyUnwrappedOptionalTypeSyntax) -> SyntaxVisitorContinueKind {
        if insideWeakVarDecl { return .visitChildren }
        let snippet = trimmedDescription(node)
        findings.append((snippet: snippet, position: node.positionAfterSkippingLeadingTrivia))
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if insideWeakVarDecl { return .visitChildren }
        if node.name.text == "Optional", node.genericArgumentClause != nil {
            let snippet = trimmedDescription(node)
            findings.append((snippet: snippet, position: node.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if let accessor = node.accessorBlock {
            walk(accessor)
        }
        return .skipChildren
    }

    private func trimmedDescription(_ node: some SyntaxProtocol) -> String {
        node.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
