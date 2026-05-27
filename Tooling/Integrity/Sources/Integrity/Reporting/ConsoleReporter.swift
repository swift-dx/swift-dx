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

import Foundation

public struct ConsoleReporter: Reporter {

    public init() {}

    public func report(_ result: EngineResult) {
        for violation in result.violations {
            FileHandle.standardError.write(Data((violation.formatted() + "\n").utf8))
        }
        if result.violations.isEmpty {
            FileHandle.standardOutput.write(Data(
                "Integrity OK: \(result.filesChecked) Swift files checked, 0 violations.\n".utf8
            ))
        } else {
            FileHandle.standardError.write(Data(
                "\nIntegrity FAILED: \(result.filesChecked) Swift files checked, \(result.violations.count) violation(s).\n".utf8
            ))
        }
    }
}
