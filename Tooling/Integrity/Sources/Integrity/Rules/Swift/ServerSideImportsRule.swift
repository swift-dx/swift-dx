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

public struct ServerSideImportsRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "ServerSideImports"
    public let ruleArea: RuleArea = .swift
    public let summary = "Forbid imports of Apple-platform-only UI modules (UIKit, SwiftUI, AppKit) unavailable on Linux."

    private let bannedModules: Set<String>

    public init(
        bannedModules: [String] = ["UIKit", "SwiftUI", "AppKit", "Cocoa", "WatchKit", "CarPlay"],
        ruleID: String = "S006"
    ) {
        self.bannedModules = Set(bannedModules)
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        let visitor = ImportVisitor(banned: bannedModules)
        visitor.walk(file.syntaxTree)
        return visitor.findings.map { finding in
            Violation(
                file: file.path,
                line: file.lineNumber(of: finding.position),
                ruleID: ruleID,
                ruleName: ruleName,
                message: "import '\(finding.module)' is not allowed in server-side Swift; module is unavailable on Linux.",
                severity: .error
            )
        }
    }
}

private final class ImportVisitor: SyntaxVisitor {

    let banned: Set<String>
    var findings: [(module: String, position: AbsolutePosition)] = []

    init(banned: Set<String>) {
        self.banned = banned
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let firstComponent = node.path.first else {
            return .visitChildren
        }
        let topModule = firstComponent.name.text
        if banned.contains(topModule) {
            findings.append((module: topModule, position: node.positionAfterSkippingLeadingTrivia))
        }
        return .visitChildren
    }
}
