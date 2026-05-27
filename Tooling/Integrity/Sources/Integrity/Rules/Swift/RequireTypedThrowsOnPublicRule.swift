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

public struct RequireTypedThrowsOnPublicRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "RequireTypedThrowsOnPublic"
    public let ruleArea: RuleArea = .swift
    public let summary = "Require typed throws on every public/open throwing function or initializer."

    public init(ruleID: String = "S010") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = UntypedThrowsVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Public \(finding.kind) declares untyped 'throws'. Replace with 'throws(SomeError)' so the failure contract is explicit.",
                severity: .error
            )
        }
    }
}

private final class UntypedThrowsVisitor: SyntaxVisitor {

    struct Finding {
        let kind: String
        let position: AbsolutePosition
    }

    var findings: [Finding] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        check(
            kind: "function '\(node.name.text)'",
            modifiers: node.modifiers,
            effectSpecifiers: node.signature.effectSpecifiers,
            parameterClause: node.signature.parameterClause,
            fallbackPosition: node.name.positionAfterSkippingLeadingTrivia
        )
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        check(
            kind: "initializer",
            modifiers: node.modifiers,
            effectSpecifiers: node.signature.effectSpecifiers,
            parameterClause: node.signature.parameterClause,
            fallbackPosition: node.initKeyword.positionAfterSkippingLeadingTrivia
        )
        return .visitChildren
    }

    private func check(
        kind: String,
        modifiers: DeclModifierListSyntax,
        effectSpecifiers: FunctionEffectSpecifiersSyntax?,
        parameterClause: FunctionParameterClauseSyntax,
        fallbackPosition: AbsolutePosition
    ) {
        let isPublic = modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.public) || modifier.name.tokenKind == .keyword(.open)
        }
        guard isPublic else { return }
        guard let throwsClause = effectSpecifiers?.throwsClause else { return }
        guard throwsClause.throwsSpecifier.tokenKind == .keyword(.throws) else { return }
        guard throwsClause.type == nil else { return }
        if hasUntypedThrowingClosureParameter(parameterClause) { return }
        let position = throwsClause.throwsSpecifier.positionAfterSkippingLeadingTrivia
        findings.append(Finding(kind: kind, position: position == fallbackPosition ? fallbackPosition : position))
    }

    private func hasUntypedThrowingClosureParameter(_ clause: FunctionParameterClauseSyntax) -> Bool {
        for parameter in clause.parameters {
            if closureTypeHasUntypedThrows(parameter.type) {
                return true
            }
        }
        return false
    }

    private func closureTypeHasUntypedThrows(_ type: TypeSyntax) -> Bool {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return closureTypeHasUntypedThrows(attributed.baseType)
        }
        guard let functionType = type.as(FunctionTypeSyntax.self) else { return false }
        guard let throwsClause = functionType.effectSpecifiers?.throwsClause else { return false }
        guard throwsClause.throwsSpecifier.tokenKind == .keyword(.throws) else { return false }
        return throwsClause.type == nil
    }
}
