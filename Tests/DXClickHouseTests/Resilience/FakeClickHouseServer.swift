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

import DXClickHouse
import Dispatch
import Foundation
import Synchronization

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// In-process TCP server that speaks just enough of the ClickHouse Native
// handshake to let a real ClickHouseConnection finish connecting, then
// behaves as the test directs. It lets socket-level connection and pool
// behaviour be exercised without a live broker. The ServerHello is built
// for a caller-chosen protocol revision, so a test can negotiate down to
// a revision that omits the handshake tail (anything below 54_058) or up
// to one that carries the INSERT write counters in Progress packets.
final class FakeClickHouseServer: @unchecked Sendable {

    enum AfterHandshake: Sendable {
        case vanish
        case sendThenClose([UInt8])
        // Close the listener (so any reconnect attempt is refused) but
        // keep the accepted client socket open and silent. Models a broker
        // that has gone unreachable while a request is in flight.
        case holdSilentCloseListener
    }

    // One step of a scripted request/reply exchange that runs after the
    // handshake completes. `drainRequest` reads (and discards) one client
    // request packet; `reply` writes canned response bytes. A test scripts
    // a query/result/ping exchange by alternating the two.
    enum ScriptStep: Sendable {
        case drainRequest
        case reply([UInt8])
        case delay(milliseconds: Int)
        // Blocks reading from the client until it shuts the socket down,
        // holding the connection open and silent until then. Models a server
        // that has sent a partial result and then stalled indefinitely, so a
        // test can verify the client tears the connection down on cancel
        // rather than parking forever in recv.
        case awaitClientClose
    }

    let port: Int
    private let listenHandle: Int32
    private let queue = DispatchQueue(label: "fake-clickhouse-server")
    let finished = DispatchSemaphore(value: 0)
    private let heldClient = Atomic<Int32>(-1)
    private let captured = Mutex<[[UInt8]]>([])

    // Raw bytes of every request drained by a `.drainRequest` script
    // step, in order. A test reads this after `finished.wait()` to assert
    // what the client actually put on the wire (e.g. that a bound query
    // parameter was transmitted rather than silently dropped).
    var capturedRequests: [[UInt8]] {
        captured.withLock { $0 }
    }

    init() {
        #if canImport(Darwin)
        let streamType = Int32(SOCK_STREAM)
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let handle = socket(AF_INET, streamType, 0)
        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(handle, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(handle, 1)

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(handle, raw, &length)
            }
        }
        listenHandle = handle
        port = Int(UInt16(bigEndian: bound.sin_port))
    }

    func run(serverHello: [UInt8], afterHandshake: AfterHandshake) {
        let handle = listenHandle
        queue.async { [self] in
            let client = accept(handle, nil, nil)
            if client >= 0 {
                Self.drain(client)
                Self.send(serverHello, to: client)
                Self.readExactly(client, count: Self.addendumByteCount(forServerHello: serverHello))
                switch afterHandshake {
                case .vanish:
                    close(client)
                case .sendThenClose(let bytes):
                    Self.send(bytes, to: client)
                    close(client)
                case .holdSilentCloseListener:
                    heldClient.store(client, ordering: .releasing)
                }
            }
            close(handle)
            finished.signal()
        }
    }

    // Completes the handshake, then walks a scripted request/reply
    // exchange so a test can drive a full query (and a following ping or
    // second query) against an in-process server with deterministic
    // response bytes.
    func run(serverHello: [UInt8], script: [ScriptStep]) {
        let handle = listenHandle
        queue.async { [self] in
            let client = accept(handle, nil, nil)
            if client >= 0 {
                Self.drain(client)
                Self.send(serverHello, to: client)
                Self.readExactly(client, count: Self.addendumByteCount(forServerHello: serverHello))
                for step in script {
                    switch step {
                    case .drainRequest:
                        let request = Self.drainReturning(client)
                        captured.withLock { $0.append(request) }
                    case .reply(let bytes):
                        Self.send(bytes, to: client)
                    case .delay(let milliseconds):
                        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000.0)
                    case .awaitClientClose:
                        Self.awaitClose(client)
                    }
                }
                close(client)
            }
            close(handle)
            finished.signal()
        }
    }

    // Runs one script per accepted connection, in order. Models a client that
    // tears its socket down mid-session and reconnects: the first script drives
    // the connection up to the teardown, the next script serves the operation
    // issued on the reconnected socket.
    func runScripts(serverHello: [UInt8], scripts: [[ScriptStep]]) {
        let handle = listenHandle
        queue.async { [self] in
            for script in scripts {
                let client = accept(handle, nil, nil)
                if client < 0 { break }
                Self.drain(client)
                Self.send(serverHello, to: client)
                Self.readExactly(client, count: Self.addendumByteCount(forServerHello: serverHello))
                for step in script {
                    switch step {
                    case .drainRequest:
                        let request = Self.drainReturning(client)
                        captured.withLock { $0.append(request) }
                    case .reply(let bytes):
                        Self.send(bytes, to: client)
                    case .delay(let milliseconds):
                        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000.0)
                    case .awaitClientClose:
                        Self.awaitClose(client)
                    }
                }
                close(client)
            }
            close(handle)
            finished.signal()
        }
    }

    // Handshakes the first connection then closes it (so the next client
    // operation tears the socket down), and handshakes the SECOND accepted
    // connection too — modelling a successful reconnect. Lets a test drive a
    // real reconnect (which rewrites the connection's negotiated ServerInfo)
    // and observe it concurrently.
    func runThenAcceptReconnect(serverHello: [UInt8]) {
        let handle = listenHandle
        queue.async { [self] in
            let first = accept(handle, nil, nil)
            if first >= 0 {
                Self.drain(first)
                Self.send(serverHello, to: first)
                Self.readExactly(first, count: Self.addendumByteCount(forServerHello: serverHello))
                close(first)
            }
            let second = accept(handle, nil, nil)
            if second >= 0 {
                Self.drain(second)
                Self.send(serverHello, to: second)
                Self.readExactly(second, count: Self.addendumByteCount(forServerHello: serverHello))
                _ = Self.drainReturning(second)
                close(second)
            }
            close(handle)
            finished.signal()
        }
    }

    // Handshakes the first connection, runs its script, then closes it; the
    // next accepted connection (a reconnect attempt) is answered with raw
    // `reconnectReply` bytes instead of a ServerHello — used to model a
    // server that rejects the reconnect handshake (for example with an
    // authentication-failed exception packet).
    func runThenRejectReconnect(serverHello: [UInt8], firstConnectionScript: [ScriptStep], reconnectReply: [UInt8]) {
        let handle = listenHandle
        queue.async { [self] in
            let first = accept(handle, nil, nil)
            if first >= 0 {
                Self.drain(first)
                Self.send(serverHello, to: first)
                Self.readExactly(first, count: Self.addendumByteCount(forServerHello: serverHello))
                for step in firstConnectionScript {
                    switch step {
                    case .drainRequest:
                        let request = Self.drainReturning(first)
                        captured.withLock { $0.append(request) }
                    case .reply(let bytes):
                        Self.send(bytes, to: first)
                    case .delay(let milliseconds):
                        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000.0)
                    case .awaitClientClose:
                        Self.awaitClose(first)
                    }
                }
                close(first)
            }
            let second = accept(handle, nil, nil)
            if second >= 0 {
                Self.drain(second)
                Self.send(reconnectReply, to: second)
                close(second)
            }
            close(handle)
            finished.signal()
        }
    }

    // Accepts a connection, reads the client Hello, and then stays silent:
    // it never sends a ServerHello, modelling a server (or load balancer)
    // that accepts the TCP connection but never completes the handshake.
    func runStallingHandshake() {
        let handle = listenHandle
        queue.async { [self] in
            let client = accept(handle, nil, nil)
            if client >= 0 {
                Self.drain(client)
                heldClient.store(client, ordering: .releasing)
            }
            close(handle)
            finished.signal()
        }
    }

    // Closes a client socket retained by `.holdSilentCloseListener` or
    // `runStallingHandshake`. Call once the test is finished so the
    // descriptor does not leak.
    func stop() {
        let client = heldClient.exchange(-1, ordering: .acquiringAndReleasing)
        if client >= 0 { close(client) }
    }

    // Builds a ServerHello whose revision-gated tail matches exactly what
    // ClickHouseConnection's handshake reader expects for the negotiated
    // revision (min of the client's revision and the supplied one). The
    // field order mirrors the reader, which is not strictly ascending by
    // revision number.
    static func serverHello(
        revision: UInt64,
        chunkedSend: String = "notchunked",
        chunkedRecv: String = "notchunked"
    ) -> [UInt8] {
        let effective = min(ClickHouseQueryBuilder.revision, revision)
        var bytes: [UInt8] = []
        ClickHouseWire.writeUVarInt(0, into: &bytes)
        ClickHouseWire.writeString("FakeClickHouse", into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(1, into: &bytes)
        ClickHouseWire.writeUVarInt(revision, into: &bytes)
        appendHandshakeTail(effective: effective, chunkedSend: chunkedSend, chunkedRecv: chunkedRecv, into: &bytes)
        return bytes
    }

    // Revision-gated tail fields in the exact order the connection's
    // handshake reader consumes them (which is not ascending by revision).
    private static func appendHandshakeTail(effective: UInt64, chunkedSend: String = "notchunked", chunkedRecv: String = "notchunked", into bytes: inout [UInt8]) {
        let fields: [(gate: UInt64, emit: (inout [UInt8]) -> Void)] = [
            (54_471, { ClickHouseWire.writeUVarInt(0, into: &$0) }),
            (54_058, { ClickHouseWire.writeString("UTC", into: &$0) }),
            (54_372, { ClickHouseWire.writeString("Fake", into: &$0) }),
            (54_401, { ClickHouseWire.writeUVarInt(0, into: &$0) }),
            (54_470, {
                ClickHouseWire.writeString(chunkedSend, into: &$0)
                ClickHouseWire.writeString(chunkedRecv, into: &$0)
            }),
            (54_461, { ClickHouseWire.writeUVarInt(0, into: &$0) }),
            (54_462, { ClickHouseWire.writeFixedInt(UInt64(0), into: &$0) }),
            (54_474, { ClickHouseWire.writeString("", into: &$0) }),
            (54_477, { ClickHouseWire.writeUVarInt(0, into: &$0) }),
            (54_479, { ClickHouseWire.writeUVarInt(0, into: &$0) }),
        ]
        for field in fields where effective >= field.gate {
            field.emit(&bytes)
        }
    }

    // Byte length of the client's post-ServerHello Addendum for the
    // revision this ServerHello advertised. The client gates the addendum
    // fields on the negotiated revision (an older server reads a shorter
    // addendum, or none at all), so the drain length must track the same
    // revision rather than a fixed constant.
    static func addendumByteCount(forServerHello serverHello: [UInt8]) -> Int {
        ClickHouseQueryBuilder.buildAddendum(serverRevision: serverHelloRevision(serverHello)).count
    }

    // Reads the advertised protocol revision out of an already-built
    // ServerHello: UVarInt packetType, String name, UVarInt major, UVarInt
    // minor, UVarInt revision.
    private static func serverHelloRevision(_ bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBufferPointer { buffer -> UInt64 in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            do {
                offset += try ClickHouseWire.readUVarInt(base: base, offset: offset, limit: buffer.count).1
                offset += try ClickHouseWire.readString(base: base, offset: offset, limit: buffer.count).1
                offset += try ClickHouseWire.readUVarInt(base: base, offset: offset, limit: buffer.count).1
                offset += try ClickHouseWire.readUVarInt(base: base, offset: offset, limit: buffer.count).1
                return try ClickHouseWire.readUVarInt(base: base, offset: offset, limit: buffer.count).0
            } catch {
                return 0
            }
        }
    }

    // Handshakes one connection, captures the raw Addendum bytes the client
    // sends, and stores them in `capturedRequests` for inspection. Used to
    // assert the client gates the Addendum to what the negotiated server
    // revision actually reads.
    func captureHandshakeAddendum(serverHello: [UInt8]) {
        let handle = listenHandle
        queue.async { [self] in
            let client = accept(handle, nil, nil)
            if client >= 0 {
                Self.drain(client)
                Self.send(serverHello, to: client)
                let addendum = Self.drainReturning(client)
                captured.withLock { $0.append(addendum) }
                close(client)
            }
            close(handle)
            finished.signal()
        }
    }

    private static func drain(_ client: Int32) {
        _ = drainReturning(client)
    }

    private static func drainReturning(_ client: Int32) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { raw in
            recv(client, raw.baseAddress, raw.count, 0)
        }
        guard count > 0 else { return [] }
        return Array(buffer[0..<count])
    }

    // Consumes EXACTLY `count` bytes from the socket, looping over recv
    // until they have all been read. The Addendum drain must use this
    // rather than a single recv: the client sends its query immediately
    // after the Addendum, so under scheduling delay both arrive together,
    // and a single recv(1024) would swallow the query bytes — leaving the
    // scripted drainRequest blocked forever and the client's read timing
    // out. Reading the Addendum's exact length leaves the query intact for
    // drainRequest.
    static func readExactly(_ client: Int32, count: Int) {
        guard count > 0 else { return }
        var read = 0
        var scratch = [UInt8](repeating: 0, count: count)
        while read < count {
            let got = scratch.withUnsafeMutableBytes { raw in
                recv(client, raw.baseAddress, count - read, 0)
            }
            if got <= 0 { return }
            read += got
        }
    }

    private static func awaitClose(_ client: Int32) {
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            let got = scratch.withUnsafeMutableBytes { raw in
                recv(client, raw.baseAddress, raw.count, 0)
            }
            if got <= 0 { return }
        }
    }

    private static func send(_ bytes: [UInt8], to client: Int32) {
        _ = bytes.withUnsafeBytes { raw in
            #if canImport(Glibc)
            Glibc.send(client, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            #elseif canImport(Musl)
            Musl.send(client, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            #else
            Darwin.send(client, raw.baseAddress, raw.count, 0)
            #endif
        }
    }
}
