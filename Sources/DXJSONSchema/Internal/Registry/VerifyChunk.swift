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

struct VerifyChunk<ID: Sendable>: Sendable {

    let start: Int
    let succeeded: [ID]
    let failed: [FailedVerification<ID>]
}
