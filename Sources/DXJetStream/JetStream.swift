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

import ServiceLifecycle

public enum JetStream {

    public static func connect(_ configuration: JetStreamConfiguration) async throws(JetStreamError) -> any JetStreamClient & Service {
        try await JetStreamClientImpl.connect(configuration)
    }

    public static func withClient<Result>(_ configuration: JetStreamConfiguration, _ body: (any JetStreamClient) async throws -> Result) async throws -> Result {
        let client = try await connect(configuration)
        do {
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }
}
