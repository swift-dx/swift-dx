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

@Suite("Redis pending queue")
struct RedisPendingQueueTests {

    private func submit(
        _ queue: RedisPendingQueue,
        expecting replyCount: Int,
        mode: RedisPendingQueue.DeliveryMode
    ) -> Task<[RESPValue], Error> {
        Task {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<[RESPValue], Error>) in
                queue.submit(expecting: replyCount, mode: mode, shape: .values, continuation: continuation) { }
            }
        }
    }

    @Test("a single reply resolves the request")
    func singleReply() async throws {
        let queue = RedisPendingQueue()
        let task = submit(queue, expecting: 1, mode: .collect)
        try await Task.sleep(for: .milliseconds(25))
        queue.deliver(.integer(7))
        #expect(try await task.value == [.integer(7)])
    }

    @Test("collect mode preserves reply order")
    func collectInOrder() async throws {
        let queue = RedisPendingQueue()
        let task = submit(queue, expecting: 3, mode: .collect)
        try await Task.sleep(for: .milliseconds(25))
        queue.deliver(.integer(1))
        queue.deliver(.integer(2))
        queue.deliver(.integer(3))
        #expect(try await task.value == [.integer(1), .integer(2), .integer(3)])
    }

    @Test("success-only mode surfaces the first server error")
    func successOnlyError() async throws {
        let queue = RedisPendingQueue()
        let task = submit(queue, expecting: 2, mode: .successOnly)
        try await Task.sleep(for: .milliseconds(25))
        queue.deliver(.simpleString(ByteBuffer(string: "OK")))
        queue.deliver(.error(prefix: "ERR", message: "boom"))
        await #expect(throws: RedisError.serverError(prefix: "ERR", message: "boom")) {
            try await task.value
        }
    }

    @Test("success-only mode returns no payload when all replies succeed")
    func successOnlyClean() async throws {
        let queue = RedisPendingQueue()
        let task = submit(queue, expecting: 2, mode: .successOnly)
        try await Task.sleep(for: .milliseconds(25))
        queue.deliver(.simpleString(ByteBuffer(string: "OK")))
        queue.deliver(.simpleString(ByteBuffer(string: "OK")))
        #expect(try await task.value == [])
    }

    @Test("failAll rejects every parked request")
    func failAllRejects() async throws {
        let queue = RedisPendingQueue()
        let task = submit(queue, expecting: 1, mode: .collect)
        try await Task.sleep(for: .milliseconds(25))
        queue.failAll(.connectionClosed)
        await #expect(throws: RedisError.connectionClosed) {
            try await task.value
        }
    }

    @Test("submitting after the queue is closed fails immediately")
    func submitAfterClose() async {
        let queue = RedisPendingQueue()
        queue.failAll(.connectionClosed)
        await #expect(throws: RedisError.connectionClosed) {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<[RESPValue], Error>) in
                queue.submit(expecting: 1, mode: .collect, shape: .values, continuation: continuation) { }
            }
        }
    }
}
