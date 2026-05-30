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

// Test helper. Atomically counts factory invocations from concurrent
// acquires so race-condition tests can assert "the connection factory
// was called exactly N times" without relying on shared mutable state.
actor ConnectionFactoryCallCounter {

    private var count: Int = 0

    var value: Int { count }

    func increment() {
        count += 1
    }

}
