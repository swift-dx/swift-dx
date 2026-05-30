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

@testable import DXRedis
import NIOCore
import Testing

@Suite("Redis error translation")
struct RedisErrorTests {

    private struct UnknownFailure: Error {}

    @Test("every sampled error renders a non-empty description")
    func descriptions() {
        let samples: [RedisError] = [
            .connectionClosed,
            .handshakeFailed(reason: "h"), .authenticationFailed(reason: "a"),
            .transportError(reason: "t"), .timedOut, .protocolError(reason: "p"),
            .incompleteResponse, .responseDepthLimitExceeded(limit: 64),
            .malformedLength(reason: "l"), .unexpectedResponseType(expected: "x", actual: "y"),
            .serverError(prefix: "ERR", message: "m"), .invalidDatabaseIndex(-1),
            .emptyCommand, .emptyCommandBatch, .poolExhausted(maxConnections: 8),
            .poolShutdown, .poolHasNoEndpoints,
            .jsonEncodingFailed(typeName: "T", reason: "r"),
            .jsonDecodingFailed(typeName: "T", reason: "r"), .integerConversionFailed(text: "z"),
            .utf8DecodingFailed, .cancelled,
        ]
        for error in samples {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("translate passes an existing RedisError through unchanged")
    func translatePassthrough() {
        #expect(RedisError.translate(RedisError.poolShutdown) == .poolShutdown)
    }

    @Test("translate maps cancellation")
    func translateCancellation() {
        #expect(RedisError.translate(CancellationError()) == .cancelled)
    }

    @Test("translate maps closed-channel errors to connectionClosed")
    func translateClosedChannel() {
        #expect(RedisError.translate(ChannelError.alreadyClosed) == .connectionClosed)
        #expect(RedisError.translate(ChannelError.ioOnClosedChannel) == .connectionClosed)
    }

    @Test("translate wraps an unknown error as a transport error")
    func translateUnknown() {
        guard case .transportError = RedisError.translate(UnknownFailure()) else {
            Issue.record("expected a transportError")
            return
        }
    }

    @Test("bridge translates a thrown channel error")
    func bridgeTranslates() async {
        await #expect(throws: RedisError.connectionClosed) {
            try await RedisError.bridge { throw ChannelError.alreadyClosed }
        }
    }

    @Test("bridge returns the body value when nothing throws")
    func bridgeReturnsValue() async throws {
        let value = try await RedisError.bridge { 7 }
        #expect(value == 7)
    }
}
