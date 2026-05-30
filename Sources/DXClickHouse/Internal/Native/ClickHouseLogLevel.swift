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

// Maps to the `send_logs_level` server setting. Controls how verbose
// the server is when streaming `Log` packets back to the client.
public enum ClickHouseLogLevel: String, Sendable, CaseIterable {

    case none
    case fatal
    case error
    case warning
    case information
    case debug
    case trace
    case test

}
