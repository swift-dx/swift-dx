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

extension RedisClient {

    public func sendArray(_ command: RedisCommand) async throws(RedisError) -> RedisReplyArray {
        try await executeArray(command, on: defaultDatabase)
    }

    public func sendArray(_ commands: [RedisCommand]) async throws(RedisError) -> [RedisReplyArray] {
        guard !commands.isEmpty else { return [] }
        return try await executeArrayPipeline(commands, on: defaultDatabase)
    }
}
