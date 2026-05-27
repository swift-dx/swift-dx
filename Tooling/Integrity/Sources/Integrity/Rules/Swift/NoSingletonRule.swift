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

public struct NoSingletonRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "NoSingleton"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid static singleton-style properties (shared, instance, current, default); inject instead."

    private let bannedNames: Set<String>

    public init(
        names: [String] = ["shared", "instance", "current", "default"],
        ruleID: String = "S008"
    ) {
        self.bannedNames = Set(names)
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = SingletonVisitor(banned: bannedNames)
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Singleton-style static property '\(finding.name)' forbidden. Inject an instance instead of exposing global access.",
                severity: .error
            )
        }
    }
}

private final class SingletonVisitor: SyntaxVisitor {

    struct Finding {
        let name: String
        let position: AbsolutePosition
    }

    let banned: Set<String>
    var findings: [Finding] = []

    init(banned: Set<String>) {
        self.banned = banned
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isStaticOrClass = node.modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
        }
        guard isStaticOrClass else { return .visitChildren }

        for binding in node.bindings {
            let name = nameOf(binding.pattern)
            if banned.contains(name) {
                findings.append(Finding(name: name, position: binding.positionAfterSkippingLeadingTrivia))
            }
        }
        return .visitChildren
    }

    private func nameOf(_ pattern: PatternSyntax) -> String {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            let raw = identifier.identifier.text
            if raw.hasPrefix("`") && raw.hasSuffix("`") && raw.count >= 2 {
                return String(raw.dropFirst().dropLast())
            }
            return raw
        }
        return ""
    }
}
