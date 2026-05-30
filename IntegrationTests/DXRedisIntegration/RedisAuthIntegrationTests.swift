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

import DXRedis
import NIOPosix
import Testing

@Suite("Redis authentication", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisAuthIntegrationTests {

    private func authConfiguration(password: String) -> RedisConfiguration {
        .init(
            endpoint: .init(host: RedisIntegration.host, port: RedisIntegration.authPort),
            credentials: .password(password),
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton
        )
    }

    @Test("connecting with the correct password authenticates and pings")
    func correctPasswordConnects() async throws {
        let client = try await Redis.connect(authConfiguration(password: RedisIntegration.authPassword))
        try await client.ping()
        let key = RedisIntegration.uniqueKey("auth")
        try await client.set(key, to: "secured")
        #expect(try await client.getString(key) == .found("secured"))
        _ = try await client.delete([key])
        await client.shutdown()
    }

    @Test("connecting with a wrong password fails at connect time")
    func wrongPasswordFails() async {
        await #expect(throws: RedisError.self) {
            let client = try await Redis.connect(authConfiguration(password: "definitely-the-wrong-password"))
            await client.shutdown()
        }
    }
}
