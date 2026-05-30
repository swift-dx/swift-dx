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

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Shared timing, RNG, RSS reader, and statistics helpers used by every
// stability phase. Kept deliberately small — the stability binary
// avoids reaching for the larger test helper machinery so it can be
// shipped as a standalone CLI.
enum StabilityClock {

    static func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
        let nanos = ContinuousClock.now - start
        return Double(nanos.components.attoseconds) / 1e18 + Double(nanos.components.seconds)
    }

    static func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
        let nanos = ContinuousClock.now - start
        let seconds = Double(nanos.components.seconds)
        let attos = Double(nanos.components.attoseconds) / 1e18
        return Int64((seconds + attos) * 1_000_000)
    }
}

enum StabilityStats {

    static func percentileMicroseconds(_ sortedSamples: [Int64], _ fraction: Double) -> Int64 {
        if sortedSamples.isEmpty { return 0 }
        let lastIndex = sortedSamples.count - 1
        let position = Int((Double(lastIndex) * fraction).rounded())
        return sortedSamples[min(max(position, 0), lastIndex)]
    }
}

// Splitmix64-based deterministic RNG. Identical to the integration test
// suite's helper so the runs across both can be compared.
struct StabilityRNG: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        var s = seed &+ 0x9E37_79B9_7F4A_7C15
        s = (s ^ (s >> 30)) &* 0xBF58_476D_1CE4_E5B9
        s = (s ^ (s >> 27)) &* 0x94D0_49BB_1331_11EB
        s = s ^ (s >> 31)
        self.state = s
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum StabilityRSS {

    static func currentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.resident_size
        #elseif canImport(Glibc) || canImport(Musl)
        guard let raw = try? String(contentsOfFile: "/proc/self/statm", encoding: .ascii) else {
            return 0
        }
        let parts = raw.split(separator: " ")
        guard parts.count >= 2, let rssPages = UInt64(parts[1]) else { return 0 }
        return rssPages * UInt64(getpagesize())
        #else
        return 0
        #endif
    }
}

// Minute-window latency accumulator. Records per-operation micro-
// seconds + error counts so the post-run reporter can compute drift
// from minute 0 to minute N.
struct StabilityWindow: Sendable {

    var samples: [Int64] = []
    var errors: Int = 0

    mutating func record(microseconds: Int64) {
        samples.append(microseconds)
    }

    mutating func recordError() {
        errors += 1
    }

    func p99Microseconds() -> Int64 {
        var sorted = samples
        sorted.sort()
        return StabilityStats.percentileMicroseconds(sorted, 0.99)
    }

    func p50Microseconds() -> Int64 {
        var sorted = samples
        sorted.sort()
        return StabilityStats.percentileMicroseconds(sorted, 0.50)
    }

    func p95Microseconds() -> Int64 {
        var sorted = samples
        sorted.sort()
        return StabilityStats.percentileMicroseconds(sorted, 0.95)
    }
}

// Ledger-shape padded identifier. Identical layout to the bench
// payload generator (fixed-width zero-padded decimal) so SELECTs match
// the rows already loaded in bench_ledgers.ledger_NM.
enum StabilityIdentifiers {

    static func aggregateId(_ index: Int) -> String {
        zeroPadded(value: index, width: 44)
    }

    static func aggregateKind(_ index: Int) -> String {
        zeroPadded(value: index, width: 4)
    }

    private static func zeroPadded(value: Int, width: Int) -> String {
        var digits: [UInt8] = []
        digits.reserveCapacity(20)
        var remaining = value < 0 ? -value : value
        if remaining == 0 {
            digits.append(0x30)
        } else {
            while remaining > 0 {
                digits.append(UInt8(0x30 &+ (remaining % 10)))
                remaining /= 10
            }
        }
        digits.reverse()
        if digits.count >= width {
            return String(unsafeUninitializedCapacity: width) { buffer in
                for index in 0..<width {
                    buffer[index] = digits[index]
                }
                return width
            }
        }
        let padCount = width - digits.count
        return String(unsafeUninitializedCapacity: width) { buffer in
            for index in 0..<padCount {
                buffer[index] = 0x30
            }
            for index in 0..<digits.count {
                buffer[padCount + index] = digits[index]
            }
            return width
        }
    }
}

// Spawns `sudo docker <args...>` synchronously and returns its exit
// status + stderr. Used by the fault phase to kill/restart the
// ClickHouse container without granting passwordless docker socket
// access to the bench binary directly.
enum StabilityDocker {

    struct Result: Sendable {
        let exitCode: Int32
        let stderr: String
    }

    static func run(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: stabilitySudoPath)
        process.arguments = ["-n", stabilityDockerPath] + arguments
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return Result(
                exitCode: process.terminationStatus,
                stderr: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return Result(exitCode: -1, stderr: "spawn failed: \(error)")
        }
    }
}

// TCP forwarder used by the TCP-RST and mid-receive scenarios. Accepts
// one inbound connection, opens an upstream, and pipes bytes both ways
// until `severe()` closes both halves abruptly. Closing the sockets
// with SO_LINGER=0 forces a RST instead of a clean FIN, which is how
// production middleboxes (load balancers, firewalls) terminate idle
// or filtered streams.
final class StabilityResettingForwarder: @unchecked Sendable {

    private let upstreamHost: String
    private let upstreamPort: Int
    private var listenSocket: Int32 = -1
    private var inboundSocket: Int32 = -1
    private var upstreamSocket: Int32 = -1
    private var inboundToUpstream: Thread?
    private var upstreamToInbound: Thread?
    private let lock = NSLock()
    private(set) var localPort: Int = 0
    private var severeRequested = false

    init(upstreamHost: String, upstreamPort: Int) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
    }

    // Binds a listener on 127.0.0.1:0, returns the bound port. Spawns a
    // helper Thread that accepts exactly one inbound connection, opens
    // the upstream, and starts the two bidirectional copy threads.
    func bind() throws -> Int {
        let listenFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if listenFd < 0 {
            throw NSError(domain: "StabilityForwarder", code: Int(errno), userInfo: nil)
        }
        var reuse: Int32 = 1
        _ = setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                #if canImport(Glibc)
                return SwiftGlibc.bind(listenFd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                return Darwin.bind(listenFd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        if bindResult < 0 {
            let savedErrno = errno
            close(listenFd)
            throw NSError(domain: "StabilityForwarder", code: Int(savedErrno), userInfo: nil)
        }
        if listen(listenFd, 1) < 0 {
            let savedErrno = errno
            close(listenFd)
            throw NSError(domain: "StabilityForwarder", code: Int(savedErrno), userInfo: nil)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(listenFd, generic, &length)
            }
        }
        listenSocket = listenFd
        localPort = Int(UInt16(bigEndian: bound.sin_port))

        let acceptThread = Thread { [weak self] in
            self?.acceptOnce()
        }
        acceptThread.start()
        return localPort
    }

    private func acceptOnce() {
        var clientAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inbound = withUnsafeMutablePointer(to: &clientAddress) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                accept(listenSocket, generic, &length)
            }
        }
        if inbound < 0 { return }
        let upstream = openUpstream()
        if upstream < 0 {
            close(inbound)
            return
        }
        lock.lock()
        inboundSocket = inbound
        upstreamSocket = upstream
        let shouldStop = severeRequested
        lock.unlock()
        if shouldStop {
            forceReset(socketHandle: inbound)
            forceReset(socketHandle: upstream)
            return
        }
        let inboundCopy = Thread { [weak self] in
            self?.copyBytes(from: inbound, to: upstream)
        }
        let upstreamCopy = Thread { [weak self] in
            self?.copyBytes(from: upstream, to: inbound)
        }
        inboundCopy.start()
        upstreamCopy.start()
        inboundToUpstream = inboundCopy
        upstreamToInbound = upstreamCopy
    }

    private func openUpstream() -> Int32 {
        let upstream = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if upstream < 0 { return -1 }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(upstreamPort).bigEndian
        address.sin_addr.s_addr = inet_addr(upstreamHost)
        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(upstream, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected < 0 {
            close(upstream)
            return -1
        }
        return upstream
    }

    private func copyBytes(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            while true {
                let received = recv(source, base, pointer.count, 0)
                if received <= 0 { break }
                var sent = 0
                while sent < received {
                    let wrote = send(destination, base.advanced(by: sent), received - sent, Int32(MSG_NOSIGNAL))
                    if wrote <= 0 { return }
                    sent += wrote
                }
            }
        }
    }

    // Tears down both halves with SO_LINGER=0 so the OS issues a TCP
    // RST instead of a graceful close. The client sees recv() either
    // return 0 (already-buffered FIN) or fail with ECONNRESET, which
    // is the exact shape a production middlebox produces on a
    // half-closed idle stream.
    func severe() {
        lock.lock()
        severeRequested = true
        let inbound = inboundSocket
        let upstream = upstreamSocket
        inboundSocket = -1
        upstreamSocket = -1
        lock.unlock()
        forceReset(socketHandle: inbound)
        forceReset(socketHandle: upstream)
    }

    private func forceReset(socketHandle: Int32) {
        if socketHandle < 0 { return }
        var linger = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(socketHandle, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
        close(socketHandle)
    }

    func shutdown() {
        severe()
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }
}
