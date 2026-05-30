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

import NIOCore

extension RedisError {

    static func bridge<Value>(_ body: () async throws -> Value) async throws(RedisError) -> Value {
        do {
            return try await body()
        } catch {
            throw translate(error)
        }
    }

    static func translate(_ error: any Error) -> RedisError {
        guard let redis = error as? RedisError else { return translateNonRedis(error) }
        return redis
    }

    private static func translateNonRedis(_ error: any Error) -> RedisError {
        guard !(error is CancellationError) else { return .cancelled }
        return translateTransport(error)
    }

    private static func translateTransport(_ error: any Error) -> RedisError {
        guard let channel = error as? ChannelError else { return .transportError(reason: String(describing: error)) }
        return mapChannelError(channel)
    }

    private static func mapChannelError(_ error: ChannelError) -> RedisError {
        switch error {
        case .ioOnClosedChannel, .alreadyClosed: .connectionClosed
        default: .transportError(reason: String(describing: error))
        }
    }
}
