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

public struct Violation: Sendable, Equatable, Codable {

    public let file: String
    public let line: Int
    public let ruleID: String
    public let ruleName: String
    public let message: String
    public let severity: Severity

    public init(file: String, line: Int, ruleID: String, ruleName: String, message: String, severity: Severity) {
        self.file = file
        self.line = line
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.message = message
        self.severity = severity
    }
}

extension Violation {

    public func formatted() -> String {
        "\(file):\(line): \(severity.rawValue): [\(ruleID)/\(ruleName)] \(message)"
    }
}
