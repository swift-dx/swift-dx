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

public struct NoImplSuffixRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoImplSuffix"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid 'Impl' suffix on public types; keep concrete implementations internal."

    public init(ruleID: String = "S004") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = PublicImplTypeVisitor()
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Public type '\(finding.name)' uses the 'Impl' suffix. Public surface is the protocol or value type; keep concrete implementations internal.",
                severity: .error
            )
        }
    }
}

private final class PublicImplTypeVisitor: SyntaxVisitor {

    var findings: [(name: String, position: AbsolutePosition)] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        check(name: node.name, modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        check(name: node.name, modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        check(name: node.name, modifiers: node.modifiers)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        check(name: node.name, modifiers: node.modifiers)
        return .visitChildren
    }

    private func check(name: TokenSyntax, modifiers: DeclModifierListSyntax) {
        let isPublic = modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.public) || modifier.name.tokenKind == .keyword(.open)
        }
        guard isPublic, name.text.hasSuffix("Impl") else { return }
        findings.append((name: name.text, position: name.positionAfterSkippingLeadingTrivia))
    }
}
