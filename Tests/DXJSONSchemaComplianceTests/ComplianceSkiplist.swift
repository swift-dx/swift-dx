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

enum ComplianceSkiplist {

    static let files: Set<String> = []

    static let groups: Set<String> = []

    static let cases: Set<String> = []

    static func skipsFile(_ name: String) -> Bool {
        files.contains(name)
    }

    static func skipsGroup(_ file: String, _ group: String) -> Bool {
        groups.contains("\(file) > \(group)")
    }

    static func skipsCase(_ file: String, _ group: String, _ test: String) -> Bool {
        cases.contains("\(file) > \(group) > \(test)")
    }
}
