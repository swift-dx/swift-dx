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

public struct OneTopLevelPublicTypePerFileRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "OneTopLevelPublicTypePerFile"
    public let ruleArea: RuleArea = .generic
    public let summary = "Forbid more than one top-level public type declaration per file."

    public init(ruleID: String = "G006") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let publicTypes = findTopLevelPublicTypes(in: file.syntaxTree)
        guard publicTypes.count > 1 else { return [] }

        let primary = publicTypes[0]
        return publicTypes.dropFirst().map { extra in
            Violation(
                file: file.path,
                line: file.lineNumber(of: extra.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "File already declares public type '\(primary.name)'; declaring additional public type '\(extra.name)' here violates one-public-type-per-file. Move '\(extra.name)' to its own file.",
                severity: .error
            )
        }
    }

    private func findTopLevelPublicTypes(in source: SourceFileSyntax) -> [(name: String, position: AbsolutePosition)] {
        var result: [(name: String, position: AbsolutePosition)] = []
        for item in source.statements {
            if let info = publicTypeInfo(from: item.item) {
                result.append(info)
            }
        }
        return result
    }

    private func publicTypeInfo(from syntax: CodeBlockItemSyntax.Item) -> (name: String, position: AbsolutePosition)? {
        guard let decl = syntax.as(DeclSyntax.self) else { return nil }
        if let node = decl.as(ClassDeclSyntax.self), hasPublicModifier(node.modifiers) {
            return (node.name.text, node.name.positionAfterSkippingLeadingTrivia)
        }
        if let node = decl.as(StructDeclSyntax.self), hasPublicModifier(node.modifiers) {
            return (node.name.text, node.name.positionAfterSkippingLeadingTrivia)
        }
        if let node = decl.as(EnumDeclSyntax.self), hasPublicModifier(node.modifiers) {
            return (node.name.text, node.name.positionAfterSkippingLeadingTrivia)
        }
        if let node = decl.as(ActorDeclSyntax.self), hasPublicModifier(node.modifiers) {
            return (node.name.text, node.name.positionAfterSkippingLeadingTrivia)
        }
        if let node = decl.as(ProtocolDeclSyntax.self), hasPublicModifier(node.modifiers) {
            return (node.name.text, node.name.positionAfterSkippingLeadingTrivia)
        }
        if let node = decl.as(TypeAliasDeclSyntax.self), hasPublicModifier(node.modifiers) {
            return (node.name.text, node.name.positionAfterSkippingLeadingTrivia)
        }
        return nil
    }

    private func hasPublicModifier(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.public) || modifier.name.tokenKind == .keyword(.open)
        }
    }
}
