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

// The three command entry points dispose of a Redis server error differently,
// by design. `send` throws RedisError.serverError so a single command's failure
// surfaces as a Swift error. `pipeline` returns the raw replies including any
// `.error` cases, so a caller can correlate per-command outcomes across the
// batch and decide which failures matter. `pipelineExpectingSuccess` throws on
// the first `.error` and discards the replies, for fire-and-forget batches where
// any failure should abort. Callers wanting throw-on-error semantics from a
// batch use `pipelineExpectingSuccess`; callers needing per-command results use
// `pipeline` and inspect each element with the RESPValue accessors.
extension RedisClient {

    public func send(_ command: RedisCommand) async throws(RedisError) -> RESPValue {
        try await send(command, database: defaultDatabase)
    }

    public func send(_ command: RedisCommand, database: RedisDatabaseIndex) async throws(RedisError) -> RESPValue {
        try await execute(command, on: database).throwingServerError()
    }

    public func pipeline(_ commands: [RedisCommand]) async throws(RedisError) -> [RESPValue] {
        try await pipeline(commands, database: defaultDatabase)
    }

    public func pipeline(_ commands: [RedisCommand], database: RedisDatabaseIndex) async throws(RedisError) -> [RESPValue] {
        try await executePipeline(commands, on: database)
    }

    public func pipelineExpectingSuccess(_ commands: [RedisCommand]) async throws(RedisError) {
        try await pipelineExpectingSuccess(commands, database: defaultDatabase)
    }

    public func pipelineExpectingSuccess(_ commands: [RedisCommand], database: RedisDatabaseIndex) async throws(RedisError) {
        try await executePipelineExpectingSuccess(commands, on: database)
    }
}
