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
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// The in-process FakeClickHouseServer drains the client's fixed-length
// Addendum after the handshake. The client sends its query immediately
// afterward, so under scheduling delay the Addendum and the query arrive
// coalesced in one socket buffer. A single recv would swallow the query
// bytes, blocking the scripted drainRequest forever and timing out the
// client — the source of the rare 30s flake in the scripted-reply tests.
// Reading exactly the Addendum length must leave the query intact.
@Suite("FakeClickHouseServer.readExactly consumes exactly N bytes")
struct FakeServerReadExactlyTests {

    #if canImport(Darwin)
    private static let streamType = Int32(SOCK_STREAM)
    #else
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    // Addendum length a current-revision server (>= chunked packets)
    // negotiates: quota key, send/recv chunked strings, parallel-replicas
    // version. Used only to give readExactly a realistic multi-byte count.
    private static let fullAddendumLength =
        FakeClickHouseServer.addendumByteCount(forServerHello: FakeClickHouseServer.serverHello(revision: 54_478))

    private static func writeAll(_ bytes: [UInt8], to fd: Int32) {
        _ = bytes.withUnsafeBytes { raw in
            #if canImport(Glibc)
            Glibc.send(fd, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            #elseif canImport(Musl)
            Musl.send(fd, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            #else
            Darwin.send(fd, raw.baseAddress, raw.count, 0)
            #endif
        }
    }

    private static func readAvailable(_ fd: Int32, max: Int = 256) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: max)
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    @Test("reading the Addendum length leaves a coalesced following request intact")
    func leavesRemainderIntact() throws {
        var fds: [Int32] = [0, 0]
        let made = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, Self.streamType, 0, $0.baseAddress) }
        try #require(made == 0)
        let writer = fds[0]
        let reader = fds[1]
        defer { close(writer); close(reader) }

        let addendum = [UInt8](repeating: 0xAB, count: Self.fullAddendumLength)
        let query = Array("SELECT {n:UInt8} -- the following request".utf8)
        var coalesced = addendum
        coalesced.append(contentsOf: query)
        Self.writeAll(coalesced, to: writer)

        // Drain exactly the Addendum; the query must remain on the socket.
        FakeClickHouseServer.readExactly(reader, count: addendum.count)

        let remaining = Self.readAvailable(reader)
        #expect(remaining == query)
    }

    @Test("a request split across the Addendum boundary is read in full")
    func readsExactCountAcrossSegments() throws {
        var fds: [Int32] = [0, 0]
        let made = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, Self.streamType, 0, $0.baseAddress) }
        try #require(made == 0)
        let writer = fds[0]
        let reader = fds[1]
        defer { close(writer); close(reader) }

        // Write the Addendum in two separate chunks so readExactly must
        // loop across more than one recv to consume the full count.
        let n = Self.fullAddendumLength
        Self.writeAll([UInt8](repeating: 0x01, count: n / 2), to: writer)
        Self.writeAll([UInt8](repeating: 0x02, count: n - n / 2), to: writer)
        let tail = Array("TAIL".utf8)
        Self.writeAll(tail, to: writer)

        FakeClickHouseServer.readExactly(reader, count: n)
        #expect(Self.readAvailable(reader) == tail)
    }
}
