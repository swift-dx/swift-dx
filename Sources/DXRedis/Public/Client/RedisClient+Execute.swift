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

    func execute(_ command: RedisCommand, on database: RedisDatabaseIndex) async throws(RedisError) -> RESPValue {
        try await withResilience(.verb(command.verbBytes)) {
            try await self.pool.withConnection { connection in
                try await self.ensureDatabase(database, on: connection)
                return try await connection.send(command)
            }
        }
    }

    func executePipeline(_ commands: [RedisCommand], on database: RedisDatabaseIndex) async throws(RedisError) -> [RESPValue] {
        try await withResilience(.fixed("PIPELINE")) {
            try await self.pool.withConnection { connection in
                try await self.runPipeline(commands, on: connection, database: database)
            }
        }
    }

    func executePipelineExpectingSuccess(_ commands: [RedisCommand], on database: RedisDatabaseIndex) async throws(RedisError) {
        try await withResilience(.fixed("PIPELINE")) {
            try await self.pool.withConnection { connection in
                try await self.runPipelineExpectingSuccess(commands, on: connection, database: database)
            }
        }
    }

    func executeSetPipeline(_ pairs: [RedisKeyValuePair], on database: RedisDatabaseIndex) async throws(RedisError) {
        try await withResilience(.fixed("MSET")) {
            try await self.pool.withConnection { connection in
                try await self.ensureDatabase(database, on: connection)
                try await connection.pipelineSet(pairs)
            }
        }
    }

    func executeMultiSet(_ pairs: [RedisKeyValuePair], on database: RedisDatabaseIndex) async throws(RedisError) {
        try await withResilience(.fixed("MSET")) {
            try await self.pool.withConnection { connection in
                try await self.ensureDatabase(database, on: connection)
                try await connection.multiSet(pairs)
            }
        }
    }

    func executeGetPipeline(_ keys: [RedisKey], on database: RedisDatabaseIndex) async throws(RedisError) -> [RESPValue] {
        try await withResilience(.fixed("MGET")) {
            try await self.pool.withConnection { connection in
                try await self.ensureDatabase(database, on: connection)
                return try await connection.pipelineGet(keys)
            }
        }
    }

    func executeArray(_ command: RedisCommand, on database: RedisDatabaseIndex) async throws(RedisError) -> RedisReplyArray {
        try await withResilience(.verb(command.verbBytes)) {
            try await self.pool.withConnection { connection in
                try await self.ensureDatabase(database, on: connection)
                return try await connection.sendArray(command)
            }
        }
    }

    func executeArrayPipeline(_ commands: [RedisCommand], on database: RedisDatabaseIndex) async throws(RedisError) -> [RedisReplyArray] {
        try await withResilience(.fixed("PIPELINE")) {
            try await self.pool.withConnection { connection in
                try await self.ensureDatabase(database, on: connection)
                return try await connection.sendArrayBatch(commands)
            }
        }
    }

    // Brings the leased connection onto the requested database before the
    // operation runs. SELECT is issued and acknowledged as its own round trip,
    // so the per-connection database index is only advanced once the switch is
    // confirmed; a subsequent command failing cannot leave the index stale and
    // route the next pooled caller to the wrong database. When the connection is
    // already on the requested database this is a no-op with no extra bytes.
    private func ensureDatabase(_ database: RedisDatabaseIndex, on connection: RedisConnection) async throws {
        guard connection.currentDatabase != database.value else { return }
        try await connection.selectDatabase(database.value)
    }

    private func runPipeline(_ commands: [RedisCommand], on connection: RedisConnection, database: RedisDatabaseIndex) async throws -> [RESPValue] {
        guard !commands.isEmpty else { throw RedisError.emptyCommandBatch }
        try await ensureDatabase(database, on: connection)
        return try await connection.pipeline(commands)
    }

    private func runPipelineExpectingSuccess(_ commands: [RedisCommand], on connection: RedisConnection, database: RedisDatabaseIndex) async throws {
        guard !commands.isEmpty else { throw RedisError.emptyCommandBatch }
        try await ensureDatabase(database, on: connection)
        try await connection.pipelineExpectingSuccess(commands)
    }
}
