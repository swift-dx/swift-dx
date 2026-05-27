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

enum RunnerExitCode: Int32, Sendable {

    case ok = 0
    case violations = 1
    case invalidArguments = 2
    case invalidConfig = 3
    case ioFailure = 4
}
