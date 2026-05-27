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

public protocol IntegrityRule: Sendable {

    var ruleID: String { get }
    var ruleName: String { get }
    var ruleArea: RuleArea { get }
    var summary: String { get }

    func check(_ file: SourceFile) -> [Violation]
}

public enum RuleArea: String, Sendable, Equatable, Codable, CaseIterable {

    case generic
    case swift
}
