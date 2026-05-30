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

/// Running arbitrary commands, pipelines, and server-side scripts. This is the
/// escape hatch that reaches every Redis command (including `EVAL`/`EVALSHA` Lua)
/// not covered by a typed method, and the array-reply variant for commands that
/// return aggregates (`MGET`, `LRANGE`, geo scans).
///
/// `RedisClient` conforms to this. Depend on `some RedisScripting` when a type
/// issues raw commands or scripts.
public protocol RedisScripting: Sendable {

    func send(_ command: RedisCommand) async throws(RedisError) -> RESPValue
    func send(_ command: RedisCommand, database: RedisDatabaseIndex) async throws(RedisError) -> RESPValue
    func sendArray(_ command: RedisCommand) async throws(RedisError) -> RedisReplyArray
    func sendArray(_ commands: [RedisCommand]) async throws(RedisError) -> [RedisReplyArray]

    func pipeline(_ commands: [RedisCommand]) async throws(RedisError) -> [RESPValue]
    func pipeline(_ commands: [RedisCommand], database: RedisDatabaseIndex) async throws(RedisError) -> [RESPValue]
    func pipelineExpectingSuccess(_ commands: [RedisCommand]) async throws(RedisError)
    func pipelineExpectingSuccess(_ commands: [RedisCommand], database: RedisDatabaseIndex) async throws(RedisError)
}
