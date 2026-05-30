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

import DXCore

struct SuiteFile {

    let name: String
    let groups: [JSONValue]
}

struct ComplianceFailure: CustomStringConvertible {

    let file: String
    let group: String
    let test: String
    let detail: String

    var description: String {
        "\(file) > \(group) > \(test): \(detail)"
    }
}

struct ComplianceReport {

    var passed = 0
    var skippedFiles = 0
    var skippedCases = 0
    var failures: [ComplianceFailure] = []
}
