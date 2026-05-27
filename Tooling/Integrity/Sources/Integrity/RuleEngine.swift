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

public struct EngineResult: Sendable {

    public let filesChecked: Int
    public let violations: [Violation]

    public init(filesChecked: Int, violations: [Violation]) {
        self.filesChecked = filesChecked
        self.violations = violations
    }

    public var hasErrors: Bool {
        violations.contains { $0.severity == .error }
    }
}

public struct RuleEngine: Sendable {

    public let rules: [any IntegrityRule]
    public let exemptions: [Exemption]

    public init(rules: [any IntegrityRule], exemptions: [Exemption] = []) {
        self.rules = rules
        self.exemptions = exemptions
    }

    public func run(against path: String) throws(SourceParserError) -> EngineResult {
        let filePaths = try SourceParser.discoverSwiftFiles(at: path)
        var violations: [Violation] = []
        for filePath in filePaths {
            let file = try SourceParser.loadFile(at: filePath)
            for rule in rules {
                let raised = rule.check(file)
                for violation in raised where !isExempt(violation) {
                    violations.append(violation)
                }
            }
        }
        return EngineResult(filesChecked: filePaths.count, violations: violations)
    }

    private func isExempt(_ violation: Violation) -> Bool {
        exemptions.contains { $0.covers(file: violation.file, ruleID: violation.ruleID) }
    }
}
