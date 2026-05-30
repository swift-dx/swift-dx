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

// RedisClient already implements every operation in these capability protocols
// across its feature extensions; declaring the conformances here makes the
// grouped menu available to callers who want a narrow view (some RedisValues,
// some RedisScripting) and proves the concrete client covers each capability.
extension RedisClient: RedisValues {}
extension RedisClient: RedisExpiry {}
extension RedisClient: RedisScripting {}
extension RedisClient: RedisLocking {}
extension RedisClient: RedisAdmin {}
