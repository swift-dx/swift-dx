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

public struct VerificationReport<ID: Sendable>: Sendable {

    public let succeeded: [ID]
    public let failed: [FailedVerification<ID>]

    public init(succeeded: [ID], failed: [FailedVerification<ID>]) {
        self.succeeded = succeeded
        self.failed = failed
    }

    public var successCount: Int {
        succeeded.count
    }

    public var failureCount: Int {
        failed.count
    }
}
