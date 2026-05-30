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

import Testing

@Suite
struct OfficialSuiteTests {

    @Test
    func mainlineDraft2020Suite() {
        let report = ComplianceRunner.run(SuiteLoader.mainlineFiles(), resources: SuiteLoader.remoteResources())
        Self.logSummary(report)
        Self.recordFailures(report)
        #expect(report.failures.isEmpty)
        #expect(report.passed > 0)
    }

    static func logSummary(_ report: ComplianceReport) {
        print("[COMPLIANCE] passed=\(report.passed) failed=\(report.failures.count) skippedFiles=\(report.skippedFiles) skippedCases=\(report.skippedCases)")
    }

    static func recordFailures(_ report: ComplianceReport) {
        for failure in report.failures {
            Issue.record("\(failure)")
        }
    }
}
