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

public struct FileHeaderRule: IntegrityRule {

    public let ruleID: String
    public let ruleName = "FileHeader"
    public let ruleArea: RuleArea = .generic
    public let summary = "Require an SPDX-License-Identifier line in every source file."

    private static let marker = "SPDX-License-Identifier:"

    public init(ruleID: String = "G001") {
        self.ruleID = ruleID
    }

    public func check(_ file: SourceFile) -> [Violation] {
        if file.contents.contains(Self.marker) {
            return []
        }
        return [
            Violation(
                file: file.path,
                line: 1,
                ruleID: ruleID,
                ruleName: ruleName,
                message: "Missing 'SPDX-License-Identifier:' line in file header.",
                severity: .error
            )
        ]
    }
}
