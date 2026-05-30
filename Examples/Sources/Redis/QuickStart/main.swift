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
import DXRedis
import Foundation

// Quick-start tour of the DXRedis client. Start a Redis 8+ server first, e.g.
// `docker run --rm -p 6379:6379 redis:8`, then `swift run RedisQuickStart`.

struct Session: Codable, Sendable {

    let userID: Int
    let token: String
}

let host = ProcessInfo.processInfo.environment["REDIS_HOST"] ?? "127.0.0.1"

let configuration = RedisConfiguration(
    endpoint: .init(host: host, port: 6379),
    credentials: .none,
    maxConnections: 8
)

try await Redis.withClient(configuration) { client in
    // A string value, set and read back.
    try await client.set("greeting", to: "hello from swift")
    let greeting = try await client.getString("greeting")
    print("greeting:", greeting)

    // A Codable value, JSON-encoded on the wire.
    try await client.set("session:1", toJSON: Session(userID: 1, token: "abc"))
    switch try await client.get("session:1", asJSON: Session.self) {
    case .found(let session): print("session:", session)
    case .notFound: print("session missing")
    }

    // A missing key is a named state, never nil.
    switch try await client.get("does-not-exist") {
    case .found(let bytes): print("unexpected:", bytes)
    case .notFound: print("missing key reads as notFound")
    }

    // Mass write: a million keys streamed over one pipelined connection.
    let pairs = (0..<1_000_000).map { RedisKeyValuePair(key: RedisKey("k:\($0)"), value: "v\($0)") }
    try await client.setPipelined(pairs)
    print("wrote \(pairs.count) keys")

    // Bulk read of a few of them.
    let values = try await client.get([RedisKey("k:0"), RedisKey("k:999999"), RedisKey("k:absent")])
    print("mget sample:", values)

    // An arbitrary command, for anything the typed surface does not cover.
    let pong = try await client.send(RedisCommand("PING"))
    print("ping:", try pong.stringValue())

    // A second logical database, with an atomic promotion via SWAPDB.
    let staging = try RedisDatabaseIndex(1)
    try await client.database(staging).set("config", to: "v2")
    try await client.swapDatabase(.zero, with: staging)
    print("config after swap:", try await client.getString("config"))

    // Clear the working database.
    try await client.flushDatabase(.asynchronous)
    print("flushed")
}
