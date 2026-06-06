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

import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// A control command handed from any thread to a listener's receive loop.
enum ListenerCommand: Sendable {

    case listen(String)
    case unlisten(String)
    case stop
}

// The wakeup-and-command channel between callers of a subscription and the
// dedicated thread that runs its blocking receive loop. A caller enqueues a
// command and writes one byte to a self-pipe; the receive loop polls that pipe's
// read end alongside the connection, so the otherwise-blocking read wakes and the
// loop applies every queued command. Enqueue holds the lock across the append and
// the wakeup write, so once the channel is closed no further write reaches the
// descriptor, and both pipe ends are non-blocking so the write never stalls.
//
// `@unchecked Sendable` is sound because the command list and closed flag are
// guarded by the mutex, the stop flag is atomic, and the pipe descriptors are
// immutable after init.
final class ListenerControl: @unchecked Sendable {

    private struct State {

        var pending: [ListenerCommand]
        var closed: Bool
    }

    let readDescriptor: Int32
    private let writeDescriptor: Int32
    private let state = Mutex<State>(State(pending: [], closed: false))
    private let stopRequested = Atomic<Bool>(false)

    init() throws(PostgresError) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw PostgresError.transportError(reason: "failed to open the subscription control pipe")
        }
        Self.makeNonBlocking(descriptors[0])
        Self.makeNonBlocking(descriptors[1])
        self.readDescriptor = descriptors[0]
        self.writeDescriptor = descriptors[1]
    }

    var isStopRequested: Bool {
        stopRequested.load(ordering: .acquiring)
    }

    func requestStop() {
        stopRequested.store(true, ordering: .releasing)
        enqueue(.stop)
    }

    func enqueue(_ command: ListenerCommand) {
        state.withLock { state in
            guard !state.closed else { return }
            state.pending.append(command)
            var signal: UInt8 = 1
            _ = write(writeDescriptor, &signal, 1)
        }
    }

    func drainCommands() -> [ListenerCommand] {
        state.withLock { state in
            guard !state.closed else { return [] }
            var scratch = [UInt8](repeating: 0, count: 64)
            while scratch.withUnsafeMutableBytes({ read(readDescriptor, $0.baseAddress, $0.count) }) > 0 {}
            let taken = state.pending
            state.pending.removeAll(keepingCapacity: true)
            return taken
        }
    }

    func waitForSignal(timeoutSeconds: Double) {
        var descriptor = pollfd(fd: readDescriptor, events: Int16(POLLIN), revents: 0)
        _ = poll(&descriptor, 1, Int32(timeoutSeconds * 1000))
        clearSignal()
    }

    func resignalIfPending() {
        state.withLock { state in
            guard !state.closed, !state.pending.isEmpty else { return }
            var signal: UInt8 = 1
            _ = write(writeDescriptor, &signal, 1)
        }
    }

    func close() {
        state.withLock { state in
            guard !state.closed else { return }
            state.closed = true
            _ = Glibc.close(writeDescriptor)
            _ = Glibc.close(readDescriptor)
        }
    }

    deinit {
        close()
    }

    private func clearSignal() {
        state.withLock { state in
            guard !state.closed else { return }
            var scratch = [UInt8](repeating: 0, count: 64)
            while scratch.withUnsafeMutableBytes({ read(readDescriptor, $0.baseAddress, $0.count) }) > 0 {}
        }
    }

    private static func makeNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | Int32(O_NONBLOCK))
    }
}
