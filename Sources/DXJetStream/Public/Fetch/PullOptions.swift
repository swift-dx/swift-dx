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

public struct PullOptions: Sendable, Hashable {

    public let batch: Int
    public let expires: TimeSpan
    public let wait: FetchWait

    public init(batch: Int = 100, expires: TimeSpan = .seconds(5), wait: FetchWait = .anyAvailable) {
        self.batch = batch
        self.expires = expires
        self.wait = wait
    }
}
