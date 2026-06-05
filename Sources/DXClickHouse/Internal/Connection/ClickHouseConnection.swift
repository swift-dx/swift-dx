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
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Minimum-viable synchronous TCP transport for ClickHouse Native
// protocol. POSIX socket + send + recv, no NIO, no TLS, no async.
// One arena per connection grows as needed. Caller drives the read
// loop via receiveBlocks; we only return when the server signals
// EndOfStream or raises an Exception.
//
// Reconnection: every public method that issues I/O catches transient
// socket failures (EPIPE / ECONNRESET) and unexpected mid-stream EOFs
// via the helper layer below. `sendQuery` is the safe retry point:
// if the send fails with a transient error, the connection re-opens,
// re-handshakes, and replays the send. `receiveBlocks*` cannot replay
// — once the server has begun streaming a result, an interruption
// surfaces as a typed error to the caller, but the connection is
// still reconnected so the *next* `sendQuery` works without manual
// recovery.
public final class ClickHouseConnection {

    public struct ServerInfo: Sendable {
        public let name: String
        public let major: UInt64
        public let minor: UInt64
        public let revision: UInt64
    }

    public let host: String
    public let port: Int
    public let user: String
    public let password: String
    public let database: String
    public let reconnectionPolicy: ReconnectionPolicy

    private var socketHandle: Int32 = -1
    private var reconnectSuppressed = false
    // Set from the timeout thread by shutdownSocketForTimeout and consumed
    // once on the worker thread by the recv that the shutdown unblocks. It
    // keeps that recv from entering the (potentially unbounded) reconnect
    // loop, so a query that times out against an unreachable broker fails
    // promptly instead of wedging the worker — and therefore the caller —
    // inside reconnect.
    private let timeoutTeardownRequested = Atomic<Bool>(false)
    // Set once by requestShutdown() when the owning client/connection is
    // closed for good. The reconnect loop checks it so an operation issued
    // after close fails fast instead of reviving the connection and leaking
    // a worker that spins in the unbounded always-retry reconnect against a
    // gone endpoint. The internal reconnect/handshake closes do NOT set it;
    // only the user-facing close path does.
    private let shutdownRequested = Atomic<Bool>(false)
    private var arena: ClickHouseArena
    // The negotiated ServerInfo is written on the connection's worker during
    // the handshake and every reconnect, but read off that worker — by the
    // public serverInfo accessor and by the INSERT path resolving the
    // revision before it hops onto the worker. A plain stored property would
    // race those reads against a reconnect's write, so the value lives
    // behind a mutex; the lock is taken a handful of times per query, far
    // below the wire round-trip, so the cost is irrelevant on the hot path.
    private let serverInfoStorage: Mutex<ServerInfo>
    public var serverInfo: ServerInfo { serverInfoStorage.withLock { $0 } }
    public var negotiatedRevision: UInt64 {
        min(ClickHouseQueryBuilder.revision, serverInfoStorage.withLock { $0.revision })
    }

    public init(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default",
        reconnectionPolicy: ReconnectionPolicy = .alwaysRetry
    ) throws(ClickHouseError) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.reconnectionPolicy = reconnectionPolicy
        self.arena = ClickHouseArena()
        self.serverInfoStorage = Mutex(ServerInfo(name: "", major: 0, minor: 0, revision: 0))
        try openAndHandshake()
    }

    deinit {
        if socketHandle >= 0 {
            #if canImport(Darwin)
            _ = Darwin.close(socketHandle)
            #else
            _ = Glibc.close(socketHandle)
            #endif
        }
    }

    public func close() {
        if socketHandle < 0 { return }
        #if canImport(Darwin)
        _ = Darwin.close(socketHandle)
        #else
        _ = Glibc.close(socketHandle)
        #endif
        socketHandle = -1
    }

    // Marks the connection as permanently closed so a later operation does
    // not transparently reconnect. The user-facing close path calls this
    // before close(); the internal reconnect/handshake closes do not, so
    // normal reconnection is unaffected.
    func requestShutdown() {
        shutdownRequested.store(true, ordering: .releasing)
    }

    public func sendQuery(_ sql: String) throws(ClickHouseError) {
        try sendQuery(sql, queryID: "", settings: .empty, parameters: .empty)
    }

    // Full-surface send: caller supplies a query ID (passed through to
    // server logs and surfaced in system.query_log), a settings block
    // applied for the duration of the query, and a parameter list bound
    // to `{name:Type}` placeholders in the SQL.
    public func sendQuery(
        _ sql: String,
        queryID: String,
        settings: ClickHouseQuerySettings = .empty,
        parameters: ClickHouseQueryParameters = .empty
    ) throws(ClickHouseError) {
        let bytes = try ClickHouseQueryBuilder.buildQuery(
            sql,
            queryID: queryID,
            settings: settings,
            parameters: parameters,
            revision: negotiatedRevision
        )
        try sendAllWithReconnect(bytes)
    }

    // Sends a Ping packet (type=4) and waits for the matching Pong
    // (type=4) reply. A transient send failure triggers the connection's
    // reconnect policy, so a caller using this as an application-level
    // health check gets the same transparent recovery as a query. Any
    // non-Pong packet surfaces a typed protocol error.
    public func ping() throws(ClickHouseError) {
        try sendAllWithReconnect(ClickHouseQueryBuilder.buildPing())
        try readPongReply()
    }

    // Single-shot liveness probe with NO reconnect. The pool's preflight
    // uses this to decide whether a recycled idle connection is still
    // alive: a dead connection must be reported unhealthy so the pool
    // discards it and opens a fresh one. Routing preflight through the
    // reconnecting `ping()` instead would, under the always-retry policy,
    // loop inside reconnect until the broker returned and hang acquire()
    // far past its timeout.
    public func pingOnce() throws(ClickHouseError) {
        reconnectSuppressed = true
        // Bound the probe's send and recv. A peer that vanished without
        // sending a FIN (network partition, firewall drop) would otherwise
        // leave the Pong recv blocking until the OS TCP retransmit timeout
        // (minutes), hanging the pool preflight that calls this and, with
        // it, every acquire() waiting on the connection. The timeout makes a
        // silently-dead connection fail fast so preflight discards it.
        Self.setSocketTimeout(socketHandle, duration: reconnectionPolicy.handshakeTimeout)
        defer {
            Self.setSocketTimeout(socketHandle, duration: .zero)
            reconnectSuppressed = false
        }
        try sendAllOnce(ClickHouseQueryBuilder.buildPing())
        try readPongReply()
    }

    private func readPongReply() throws(ClickHouseError) {
        let packetType = try readUVarInt()
        switch packetType {
        case 4:
            return
        case 2:
            let exception = try readExceptionPacket()
            throw .queryFailed(serverException: exception)
        default:
            throw .protocolError(stage: "ping", message: "unexpected packet type \(packetType)")
        }
    }

    // Sends a Cancel packet (type=3). The server stops streaming Data
    // packets and follows with EndOfStream; the caller is responsible
    // for draining packets until the terminator arrives.
    public func sendCancel() throws(ClickHouseError) {
        try sendAllOnce(ClickHouseQueryBuilder.buildCancel())
    }

    // Used by the per-query timeout path. Calls shutdown(SHUT_RDWR) on
    // the live socket file descriptor from a thread other than the one
    // running this connection's worker queue. The blocked recv()/send()
    // on the worker returns immediately (errno or 0), the worker
    // surfaces a typed I/O error, and the reconnect path establishes a
    // fresh socket for the next operation.
    //
    // Idempotent. Safe to call from any thread. The read of
    // `socketHandle` is a single word and races benignly with a
    // concurrent close() — if the descriptor has just been recycled the
    // shutdown call sees ENOTCONN and returns without affecting the
    // unrelated FD.
    package func shutdownSocketForTimeout() {
        timeoutTeardownRequested.store(true, ordering: .releasing)
        let handle = socketHandle
        if handle < 0 { return }
        #if canImport(Darwin)
        _ = Darwin.shutdown(handle, SHUT_RDWR)
        #else
        _ = Glibc.shutdown(handle, Int32(SHUT_RDWR))
        #endif
    }

    // Pulls server packets until EndOfStream. Calls `consume` only for
    // genuine result Data packets (type 1). Totals, Extremes, Log, and
    // ProfileEvents blocks are metadata — they are read off the wire to
    // stay framed but are NOT delivered to `consume`, so a `WITH TOTALS`
    // or `extremes=1` query does not inject the totals/extremes block as
    // a phantom extra result row indistinguishable from real data.
    // Returns the cumulative row count across the result Data packets.
    // Runs a result-reading loop and, on any failure that leaves the stream
    // mid-block — an unsupported or malformed column the copy could not size
    // and drain, or a truncated packet — closes the connection so the next
    // operation transparently reconnects instead of reading stale bytes off
    // the wire. A server query exception is the one clean case: it ends the
    // result at a packet boundary, so the connection stays usable.
    func closingOnBrokenRead<Result>(_ body: () throws -> Result) throws(ClickHouseError) -> Result {
        do {
            return try body()
        } catch {
            let typed = (error as? ClickHouseError) ?? .protocolError(stage: "receiveBlocks", message: "\(error)")
            if case .queryFailed = typed { throw typed }
            close()
            throw typed
        }
    }

    public func receiveBlocks(_ consume: (ClickHouseBlock, UnsafeRawBufferPointer) throws -> Void) throws(ClickHouseError) -> Int {
        try closingOnBrokenRead {
            var totalRows = 0
            while true {
                switch try readNextDataBlock(consume: consume) {
                case .block(let rowCount): totalRows += rowCount
                case .endOfStream: return totalRows
                }
            }
        }
    }

    // Reads packets forward until the next result Data block — which it delivers
    // through `consume` and reports as `.block(rowCount:)` — or EndOfStream,
    // reported as `.endOfStream`. Progress, ProfileInfo, Totals/Extremes, Log,
    // ProfileEvents, TableColumns, TimezoneUpdate, and Pong packets are read off
    // the wire to stay framed but are not results, so the loop continues past
    // them. A server Exception throws `queryFailed` at a clean packet boundary.
    // Resumable: each call advances exactly one result block, so a backpressured
    // streaming consumer can pull one block at a time instead of draining the
    // whole result eagerly. Callers wrap this in `closingOnBrokenRead` so a
    // broken mid-block read tears the connection down for transparent reconnect.
    func readNextDataBlock(consume: (ClickHouseBlock, UnsafeRawBufferPointer) throws -> Void) throws(ClickHouseError) -> ClickHouseReceiveStep {
        while true {
            let packetType = try readUVarInt()
            switch packetType {
            case 1: // Data
                let rowCount = try readBlockPacket(revision: negotiatedRevision, consume: consume)
                return .block(rowCount: rowCount)
            case 2:
                let exception = try readExceptionPacket()
                throw ClickHouseError.queryFailed(serverException: exception)
            case 3:
                try skipProgressPacket(revision: negotiatedRevision)
            case 5:
                return .endOfStream
            case 6:
                try skipProfileInfoPacket(revision: negotiatedRevision)
            case 7, 8: // Totals / Extremes — metadata, not result rows; skip
                _ = try readString() // table name
                try skipBlock(revision: negotiatedRevision)
            case 10, 14: // Log / ProfileEvents
                _ = try readString() // table name
                try skipBlock(revision: negotiatedRevision)
            case 11:
                _ = try readString()
                _ = try readString()
            case 17:
                _ = try readString() // timezone update
            case 4: // pong
                continue
            default:
                throw ClickHouseError.protocolError(stage: "receiveBlocks", message: "unexpected packet type \(packetType)")
            }
        }
    }

    // Callback set delivered to `receiveBlocksWithCallbacks`. Each
    // closure is invoked synchronously on the worker thread that is
    // draining the connection; the closure is expected to be cheap.
    // Default closures throw nothing and ignore the event so callers
    // can opt in to only the signals they need.
    public struct ReceiveCallbacks {

        public var onProgress: (ClickHouseProgress) -> Void
        public var onProfileInfo: (ClickHouseProfileInfo) -> Void
        public var onProfileEvents: (ClickHouseProfileEvents) -> Void

        public init(
            onProgress: @escaping (ClickHouseProgress) -> Void = { _ in },
            onProfileInfo: @escaping (ClickHouseProfileInfo) -> Void = { _ in },
            onProfileEvents: @escaping (ClickHouseProfileEvents) -> Void = { _ in }
        ) {
            self.onProgress = onProgress
            self.onProfileInfo = onProfileInfo
            self.onProfileEvents = onProfileEvents
        }
    }

    // Same as `receiveBlocks` but raises Progress, ProfileInfo, and
    // ProfileEvents packets to the caller via the supplied callbacks
    // instead of silently dropping them. Exception packets still throw
    // `queryFailed`; EndOfStream still returns the cumulative row count.
    public func receiveBlocks(
        callbacks: ReceiveCallbacks,
        _ consume: (ClickHouseBlock, UnsafeRawBufferPointer) throws -> Void
    ) throws(ClickHouseError) -> Int {
        try closingOnBrokenRead {
            var totalRows = 0
            while true {
                let packetType = try readUVarInt()
                switch packetType {
                case 1:
                    totalRows += try readBlockPacket(revision: negotiatedRevision, consume: consume)
                case 2:
                    let exception = try readExceptionPacket()
                    throw ClickHouseError.queryFailed(serverException: exception)
                case 3:
                    let progress = try readProgressPacket(revision: negotiatedRevision)
                    callbacks.onProgress(progress)
                case 5:
                    return totalRows
                case 6:
                    let profileInfo = try readProfileInfoPacket(revision: negotiatedRevision)
                    callbacks.onProfileInfo(profileInfo)
                case 7, 8: // Totals / Extremes — metadata, not result rows; skip
                    _ = try readString() // table name
                    try skipBlock(revision: negotiatedRevision)
                case 14:
                    let hostName = try readString()
                    try skipBlock(revision: negotiatedRevision)
                    callbacks.onProfileEvents(ClickHouseProfileEvents(hostName: hostName))
                case 10:
                    _ = try readString()
                    try skipBlock(revision: negotiatedRevision)
                case 11:
                    _ = try readString()
                    _ = try readString()
                case 17:
                    _ = try readString()
                case 4:
                    continue
                default:
                    throw ClickHouseError.protocolError(stage: "receiveBlocks", message: "unexpected packet type \(packetType)")
                }
            }
        }
    }

    // Drain-only variant with the full callback set. Same packet
    // handling as `receiveBlocks(callbacks:_:)` but the per-block
    // body bytes are dropped instead of being copied for the caller.
    public func receiveBlocksDrain(
        callbacks: ReceiveCallbacks,
        _ consume: (Int, [String], [String]) throws -> Void
    ) throws(ClickHouseError) -> Int {
        try closingOnBrokenRead {
            var totalRows = 0
            while true {
                let packetType = try readUVarInt()
                switch packetType {
                case 1:
                    totalRows += try drainBlockPacket(revision: negotiatedRevision, consume: consume)
                case 7, 8: // Totals / Extremes — metadata, not result rows; skip
                    _ = try readString() // table name
                    try skipBlock(revision: negotiatedRevision)
                case 2:
                    let exception = try readExceptionPacket()
                    throw ClickHouseError.queryFailed(serverException: exception)
                case 3:
                    let progress = try readProgressPacket(revision: negotiatedRevision)
                    callbacks.onProgress(progress)
                case 5:
                    return totalRows
                case 6:
                    let profileInfo = try readProfileInfoPacket(revision: negotiatedRevision)
                    callbacks.onProfileInfo(profileInfo)
                case 14:
                    let hostName = try readString()
                    try skipBlock(revision: negotiatedRevision)
                    callbacks.onProfileEvents(ClickHouseProfileEvents(hostName: hostName))
                case 10:
                    _ = try readString()
                    try skipBlock(revision: negotiatedRevision)
                case 11:
                    _ = try readString()
                    _ = try readString()
                case 17:
                    _ = try readString()
                case 4:
                    continue
                default:
                    throw ClickHouseError.protocolError(stage: "receiveBlocksDrain", message: "unexpected packet type \(packetType)")
                }
            }
        }
    }

    // Drain-only variant: skips every column body (including composite
    // types: LowCardinality, Array, Nullable, Map, JSON) without
    // materialising them into a Swift-visible buffer. The consume
    // callback receives the per-block metadata only. Returns total row
    // count across data blocks. This is the FLOOR measurement path —
    // wire bytes flow through recv() into the arena, get parsed, and
    // get dropped without ever crossing into Swift `[UInt8]` allocation
    // on the body bytes.
    public func receiveBlocksDrain(_ consume: (Int, [String], [String]) throws -> Void) throws(ClickHouseError) -> Int {
        try closingOnBrokenRead {
            var totalRows = 0
            while true {
                let packetType = try readUVarInt()
                switch packetType {
                case 1:
                    totalRows += try drainBlockPacket(revision: negotiatedRevision, consume: consume)
                case 7, 8: // Totals / Extremes — metadata, not result rows; skip
                    _ = try readString() // table name
                    try skipBlock(revision: negotiatedRevision)
                case 2:
                    let exception = try readExceptionPacket()
                    throw ClickHouseError.queryFailed(serverException: exception)
                case 3:
                    try skipProgressPacket(revision: negotiatedRevision)
                case 5:
                    return totalRows
                case 6:
                    try skipProfileInfoPacket(revision: negotiatedRevision)
                case 10, 14:
                    _ = try readString()
                    try skipBlock(revision: negotiatedRevision)
                case 11:
                    _ = try readString()
                    _ = try readString()
                case 17:
                    _ = try readString()
                case 4:
                    continue
                default:
                    throw ClickHouseError.protocolError(stage: "receiveBlocksDrain", message: "unexpected packet type \(packetType)")
                }
            }
        }
    }

    // String-extracting variant: skips every non-String column body and
    // copies bodies of columns whose type is exactly `String` or
    // `FixedString(N)` into a per-column [UInt8] buffer that the
    // consumer can index. For LowCardinality(String) the dictionary
    // body is decoded into the buffer and indices skipped (the bench
    // uses this for counting matched values, not for projecting
    // ordered rows). Returns total row count across data blocks.
    public func receiveBlocksExtractingStrings(_ consume: (Int, [String], [String], [[UInt8]]) throws -> Void) throws(ClickHouseError) -> Int {
        try closingOnBrokenRead {
            var totalRows = 0
            while true {
                let packetType = try readUVarInt()
                switch packetType {
                case 1:
                    totalRows += try extractStringsBlockPacket(revision: negotiatedRevision, consume: consume)
                case 7, 8: // Totals / Extremes — metadata, not result rows; skip
                    _ = try readString() // table name
                    try skipBlock(revision: negotiatedRevision)
                case 2:
                    let exception = try readExceptionPacket()
                    throw ClickHouseError.queryFailed(serverException: exception)
                case 3:
                    try skipProgressPacket(revision: negotiatedRevision)
                case 5:
                    return totalRows
                case 6:
                    try skipProfileInfoPacket(revision: negotiatedRevision)
                case 10, 14:
                    _ = try readString()
                    try skipBlock(revision: negotiatedRevision)
                case 11:
                    _ = try readString()
                    _ = try readString()
                case 17:
                    _ = try readString()
                case 4:
                    continue
                default:
                    throw ClickHouseError.protocolError(stage: "receiveBlocksExtractingStrings", message: "unexpected packet type \(packetType)")
                }
            }
        }
    }

    // Single-scalar variant: drains one block containing one row + one
    // column and returns the body bytes for that column. Used by the
    // bench scalar-count path (count() queries). Throws if the result
    // is not exactly one row + one fixed-width column.
    public func receiveScalarUInt64() throws(ClickHouseError) -> UInt64 {
        var result: UInt64 = 0
        var observed = false
        let rows = try receiveBlocks { block, body in
            guard !observed else { return }
            guard block.rowCount == 1, block.columnCount == 1 else { return }
            guard body.count >= 8 else { return }
            var storage: UInt64 = 0
            withUnsafeMutableBytes(of: &storage) { destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(start: body.baseAddress, count: 8))
            }
            result = UInt64(littleEndian: storage)
            observed = true
        }
        if !observed || rows != 1 {
            throw .protocolError(stage: "receiveScalarUInt64", message: "expected exactly one UInt64 scalar")
        }
        return result
    }

    // Package-internal accessors used by the Codable INSERT path
    // (ClickHouseConnection+Insert.swift). These thin wrappers
    // forward to the same private helpers the sync receive loop uses,
    // without widening the public surface of the type.
    internal func readUVarIntInternal() throws(ClickHouseError) -> UInt64 {
        try readUVarInt()
    }

    internal func readStringInternal() throws(ClickHouseError) -> String {
        try readString()
    }

    internal func readExceptionPacketInternal() throws(ClickHouseError) -> ClickHouseServerException {
        try readExceptionPacket()
    }

    internal func skipProgressPacketInternal() throws(ClickHouseError) {
        try skipProgressPacket(revision: negotiatedRevision)
    }

    internal func readProgressPacketInternal() throws(ClickHouseError) -> ClickHouseProgress {
        try readProgressPacket(revision: negotiatedRevision)
    }

    internal func skipProfileInfoPacketInternal() throws(ClickHouseError) {
        try skipProfileInfoPacket(revision: negotiatedRevision)
    }

    internal func skipBlockInternal() throws(ClickHouseError) {
        try skipBlock(revision: negotiatedRevision)
    }

    internal func parseSampleBlockHeaderInternal() throws(ClickHouseError) -> [ClickHouseConnection.InsertSchemaColumn] {
        _ = try readString() // table name
        let prologue = try parsePrologue()
        var schema: [ClickHouseConnection.InsertSchemaColumn] = []
        schema.reserveCapacity(prologue.columnCount)
        for _ in 0..<prologue.columnCount {
            let header = try parseColumnHeader(revision: negotiatedRevision)
            let expandedType = ClickHouseGeoTypeName.expand(header.type)
            try skipColumnBody(typeName: expandedType, rows: prologue.rowCount)
            schema.append(.init(name: header.name, typeName: expandedType))
        }
        arena.compact()
        return schema
    }

    internal func sendAllWithReconnectInternal(_ bytes: [UInt8]) throws(ClickHouseError) {
        try sendAllWithReconnect(bytes)
    }

    // Sends without the reconnect-and-replay step. Used for bytes that are
    // only meaningful in the middle of an exchange already opened by a
    // prior sendQuery (an INSERT data block, its terminator). Replaying
    // those on a freshly handshaked socket — which never received the
    // INSERT query — would feed the server an unexpected packet and desync
    // the stream, so a send failure here fails the operation outright and
    // recovery happens when the next sendQuery reopens the connection.
    internal func sendAllOnceInternal(_ bytes: [UInt8]) throws(ClickHouseError) {
        try sendAllOnce(bytes)
    }

    internal func sendAllVectoredInternal(_ first: [UInt8], _ second: [UInt8]) throws(ClickHouseError) {
        try sendAllVectored(first, second)
    }

    // Opens a fresh socket, sends Hello, parses ServerHello, sends
    // Addendum. Used by init and by every reconnect attempt. The arena
    // is reset to empty before each handshake to drop any stale bytes
    // left over from a torn connection.
    private func openAndHandshake() throws(ClickHouseError) {
        arena.head = 0
        arena.tail = 0
        let handle = try Self.openSocket(host: host, port: port)
        socketHandle = handle
        // Bound the handshake: a server that accepts but never answers the
        // Hello would otherwise park recv forever. Suppress reconnect for
        // the duration so a timed-out handshake recv fails fast (init
        // surfaces the error; reconnect's own loop handles retries)
        // instead of recursively reconnecting.
        Self.setSocketTimeout(handle, duration: reconnectionPolicy.handshakeTimeout)
        reconnectSuppressed = true
        defer { reconnectSuppressed = false }
        do {
            try sendAllOnce(ClickHouseQueryBuilder.buildHello(database: database, user: user, password: password))
            let negotiated = try receiveHello()
            serverInfoStorage.withLock { $0 = negotiated }
            let addendum = ClickHouseQueryBuilder.buildAddendum(serverRevision: negotiated.revision)
            if !addendum.isEmpty {
                try sendAllOnce(addendum)
            }
        } catch {
            close()
            throw error
        }
        Self.setSocketTimeout(handle, duration: .zero)
    }

    private static func setSocketTimeout(_ handle: Int32, duration: Duration) {
        let components = duration.components
        var tv = timeval()
        tv.tv_sec = numericCast(components.seconds)
        tv.tv_usec = numericCast(components.attoseconds / 1_000_000_000_000)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // Reconnect with bounded exponential backoff. Each attempt sleeps
    // for the current backoff, then tries to re-establish the socket
    // and complete the handshake. Returns normally on success; throws
    // `.reconnectExhausted` if every attempt fails.
    //
    // `maxAttempts == ReconnectionPolicy.unboundedAttempts` (Int.max) is
    // treated as "retry forever until the broker comes back". This is
    // the value the always-retry default places in the policy.
    private func reconnect() throws(ClickHouseError) {
        if shutdownRequested.load(ordering: .acquiring) {
            throw .connectionFailed(reason: "connection has been closed")
        }
        if reconnectionPolicy.maxAttempts <= 0 {
            throw .reconnectExhausted(attempts: 0)
        }
        close()
        var backoff = reconnectionPolicy.initialBackoff
        var attempt = 0
        let isUnbounded = reconnectionPolicy.maxAttempts == ReconnectionPolicy.unboundedAttempts
        while isUnbounded || attempt < reconnectionPolicy.maxAttempts {
            // Re-checked every iteration, not only on entry: close() (or the
            // owning client's deinit) sets shutdownRequested from another thread,
            // and under the unbounded always-retry policy a backoff loop against a
            // gone server would otherwise spin forever, leaking the worker thread
            // and blocking process exit. The check breaks the loop at the next
            // wake so a closed or dropped client stops retrying.
            if shutdownRequested.load(ordering: .acquiring) {
                throw .connectionFailed(reason: "connection has been closed")
            }
            attempt += 1
            sleepFor(duration: Self.jitteredBackoff(backoff, fraction: Double.random(in: 0..<1)))
            do {
                try openAndHandshake()
                return
            } catch {
                // A server that answers the handshake with an exception
                // (authentication failed, unknown database, access denied)
                // is actively refusing this client, not transiently
                // unreachable. Retrying cannot change the outcome, so fail
                // fast instead of looping the backoff — and, under the
                // unbounded always-retry policy, forever.
                if case .queryFailed = error {
                    throw error
                }
                backoff = nextBackoff(current: backoff)
            }
        }
        throw .reconnectExhausted(attempts: reconnectionPolicy.maxAttempts)
    }

    // Spreads each reconnect sleep within the lower-and-upper half of the
    // nominal backoff ("equal jitter"): the wait is at least half the
    // backoff and at most the full backoff, with `fraction` (in [0, 1))
    // placing it inside that window. Without this, every connection that
    // dropped at the same instant would retry in lockstep on identical
    // 100ms/200ms/400ms boundaries and stampede a recovering broker the
    // moment it returns. The nominal `backoff` itself is left unchanged so
    // the exponential growth envelope does not drift across attempts. A
    // non-positive backoff (the fail-fast/zero case) is returned as-is.
    static func jitteredBackoff(_ backoff: Duration, fraction: Double) -> Duration {
        let totalNanoseconds = backoff.components.seconds * 1_000_000_000
            + backoff.components.attoseconds / 1_000_000_000
        if totalNanoseconds <= 0 { return backoff }
        let safeFraction = Swift.min(Swift.max(fraction, 0.0), 0.999_999_999)
        let half = totalNanoseconds / 2
        let spread = Int64(Double(half) * safeFraction)
        return .nanoseconds(half + spread)
    }

    private func sleepFor(duration: Duration) {
        let nanos = duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        if nanos <= 0 { return }
        var spec = timespec(tv_sec: Int(nanos / 1_000_000_000), tv_nsec: Int(nanos % 1_000_000_000))
        var remainder = timespec(tv_sec: 0, tv_nsec: 0)
        _ = nanosleep(&spec, &remainder)
    }

    private func nextBackoff(current: Duration) -> Duration {
        let currentNs = current.components.seconds * 1_000_000_000 + current.components.attoseconds / 1_000_000_000
        let multiplier = max(1.0, reconnectionPolicy.backoffMultiplier)
        let scaled = Int64(Double(currentNs) * multiplier)
        let capNs = reconnectionPolicy.maxBackoff.components.seconds * 1_000_000_000
            + reconnectionPolicy.maxBackoff.components.attoseconds / 1_000_000_000
        let clamped = scaled > capNs ? capNs : scaled
        return .nanoseconds(clamped)
    }

    private func receiveHello() throws(ClickHouseError) -> ServerInfo {
        let packetType = try readUVarInt()
        if packetType == 2 {
            let exception = try readExceptionPacket()
            throw .queryFailed(serverException: exception)
        }
        guard packetType == 0 else {
            throw .protocolError(stage: "hello", message: "unexpected packet type \(packetType)")
        }
        let name = try readString()
        let major = try readUVarInt()
        let minor = try readUVarInt()
        let revision = try readUVarInt()
        try skipServerHelloTail(clientRevision: ClickHouseQueryBuilder.revision, serverRevision: revision)
        return ServerInfo(name: name, major: major, minor: minor, revision: revision)
    }

    private func skipServerHelloTail(clientRevision: UInt64, serverRevision: UInt64) throws(ClickHouseError) {
        let effective = min(clientRevision, serverRevision)
        if effective >= 54_471 { _ = try readUVarInt() } // parallelReplicasProtocolVersion
        if effective >= 54_058 { _ = try readString() } // timezone
        if effective >= 54_372 { _ = try readString() } // display name
        if effective >= 54_401 { _ = try readUVarInt() } // version patch
        if effective >= 54_470 {
            let chunkedSend = try readString()
            let chunkedRecv = try readString()
            try requireUnchunkedProtocol(send: chunkedSend, recv: chunkedRecv)
        }
        if effective >= 54_461 {
            let ruleCount = try readUVarInt()
            for _ in 0..<ruleCount {
                _ = try readString()
                _ = try readString()
            }
        }
        if effective >= 54_462 { _ = try readFixedInt(UInt64.self) }
        if effective >= 54_474 {
            // server settings list — terminated by empty-name string
            while true {
                let name = try readString()
                if name.isEmpty { break }
                _ = try readUVarInt() // flags
                _ = try readString() // value
            }
        }
        if effective >= 54_477 { _ = try readUVarInt() }
        if effective >= 54_479 { _ = try readUVarInt() }
    }

    // From revision 54470 the server advertises its chunked-framing preference
    // for each direction: "notchunked", "chunked", or an "_optional" variant.
    // This client sends "notchunked" in its addendum and reads unframed blocks,
    // so an "_optional" peer falls back to unframed. A peer that mandates
    // "chunked" (exact) would wrap every block in a length-prefixed chunk frame
    // this client would misread as block bytes, so reject it at the handshake
    // with a clear error rather than desyncing on the first result.
    private func requireUnchunkedProtocol(send: String, recv: String) throws(ClickHouseError) {
        if send == "chunked" || recv == "chunked" {
            throw .protocolError(stage: "hello", message: "server mandates chunked protocol framing (send=\(send), recv=\(recv)); this client supports only unframed (notchunked) transport")
        }
    }

    // Walks a Block (interleaved per-column header + body) without
    // exposing it to the caller. Used to drain Log and ProfileEvents
    // packets which carry text-typed columns the floor parser does not
    // expose to consumers.
    private func skipBlock(revision: UInt64) throws(ClickHouseError) {
        let prologue = try parsePrologue()
        for _ in 0..<prologue.columnCount {
            let header = try parseColumnHeader(revision: revision)
            let expandedType = ClickHouseGeoTypeName.expand(header.type)
            try skipColumnBody(typeName: expandedType, rows: prologue.rowCount)
        }
        arena.compact()
    }

    private func parsePrologue() throws(ClickHouseError) -> (columnCount: Int, rowCount: Int) {
        while true {
            let parseOutcome: ParsePrologueOutcome = arena.withReadPointer { base, available in
                do {
                    let result = try ClickHouseBlockParser.parsePrologue(base: base, offset: 0, limit: available)
                    return .ready(columnCount: result.columnCount, rowCount: result.rowCount, consumed: result.consumed)
                } catch ClickHouseParseError.needsMoreBytes {
                    return .needsMoreBytes
                } catch ClickHouseParseError.malformed(let stage, let message) {
                    return .malformed(stage: stage, message: message)
                } catch {
                    return .malformed(stage: "prologue", message: "\(error)")
                }
            }
            switch parseOutcome {
            case .ready(let columnCount, let rowCount, let consumed):
                arena.advanceHead(by: consumed)
                return (columnCount, rowCount)
            case .needsMoreBytes:
                try fillMore(minBytes: 1)
            case .malformed(let stage, let message):
                throw .protocolError(stage: stage, message: message)
            }
        }
    }

    private enum ParsePrologueOutcome {
        case ready(columnCount: Int, rowCount: Int, consumed: Int)
        case needsMoreBytes
        case malformed(stage: String, message: String)
    }

    private enum ParseColumnHeaderOutcome {
        case ready(name: String, type: String, consumed: Int)
        case needsMoreBytes
        case malformed(stage: String, message: String)
    }

    private enum ParseStringOutcome {
        case ready(value: String, consumed: Int)
        case needsMoreBytes
        case malformed(stage: String, message: String)
    }

    private func parseColumnHeader(revision: UInt64) throws(ClickHouseError) -> (name: String, type: String) {
        while true {
            let outcome: ParseColumnHeaderOutcome = arena.withReadPointer { base, available in
                do {
                    let result = try ClickHouseBlockParser.parseColumnHeader(base: base, offset: 0, limit: available, revision: revision)
                    return .ready(name: result.name, type: result.type, consumed: result.consumed)
                } catch ClickHouseParseError.needsMoreBytes {
                    return .needsMoreBytes
                } catch ClickHouseParseError.malformed(let stage, let message) {
                    return .malformed(stage: stage, message: message)
                } catch {
                    return .malformed(stage: "column header", message: "\(error)")
                }
            }
            switch outcome {
            case .ready(let name, let type, let consumed):
                arena.advanceHead(by: consumed)
                try requireBoundedTypeNesting(type)
                return (name, type)
            case .needsMoreBytes:
                try fillMore(minBytes: 1)
            case .malformed(let stage, let message):
                throw .protocolError(stage: stage, message: message)
            }
        }
    }

    // Composite type names nest the type read, parse, skip, and copy paths
    // one recursion per parenthesis level. The name is server-supplied and
    // bounded only by the 1 GiB string cap, so a hostile depth such as
    // Array(Array(...)) tens of thousands deep would overflow the thread
    // stack before any byte of the body is touched. Bound the nesting here,
    // once, ahead of every downstream recursion. Real ClickHouse types nest
    // only a handful of levels.
    private func requireBoundedTypeNesting(_ type: String) throws(ClickHouseError) {
        var depth = 0
        var maxDepth = 0
        for byte in type.utf8 {
            if byte == 0x28 { depth += 1 }
            if byte == 0x29 { depth -= 1 }
            if depth > maxDepth { maxDepth = depth }
        }
        if maxDepth > 64 {
            throw .protocolError(stage: "column header", message: "column type nesting depth \(maxDepth) exceeds the supported maximum of 64")
        }
    }

    // Reads the per-column prefix CH emits for LowCardinality, Map, and
    // Array(Tuple(...)) substreams BEFORE the column body. For a flat
    // LowCardinality(T) this is one UInt64 (KeysSerializationVersion =
    // 1); for Array(T) it recurses into the inner T; for Map(K, V) it
    // recurses into both K and V. Skipped entirely when rowCount == 0.
    private func skipColumnPrefix(typeName: String, rows: Int) throws(ClickHouseError) {
        guard rows > 0 else { return }
        if typeName.hasPrefix("LowCardinality(") {
            _ = try readFixedInt(UInt64.self)
            return
        }
        if typeName.hasPrefix("Array(") {
            let inner = innerType(typeName: typeName, prefix: "Array(")
            try skipColumnPrefix(typeName: inner, rows: rows)
            return
        }
        if typeName.hasPrefix("Map(") {
            let inner = innerType(typeName: typeName, prefix: "Map(")
            let (keyType, valueType) = Self.splitMapInner(inner)
            try skipColumnPrefix(typeName: keyType, rows: rows)
            try skipColumnPrefix(typeName: valueType, rows: rows)
            return
        }
        if typeName.hasPrefix("Tuple(") {
            let elements = try ClickHouseTupleTypeSplitter.split(typeName: typeName)
            for element in elements {
                try skipColumnPrefix(typeName: element.type, rows: rows)
            }
            return
        }
        if typeName.hasPrefix("Nullable(") {
            let inner = innerType(typeName: typeName, prefix: "Nullable(")
            try skipColumnPrefix(typeName: inner, rows: rows)
            return
        }
    }

    private func skipColumnBody(typeName: String, rows: Int) throws(ClickHouseError) {
        try skipColumnPrefix(typeName: typeName, rows: rows)
        try skipColumnBodyAfterPrefix(typeName: typeName, rows: rows)
    }

    private func skipColumnBodyAfterPrefix(typeName: String, rows: Int) throws(ClickHouseError) {
        if typeName.hasPrefix("LowCardinality(") {
            try skipLowCardinalityBody(typeName: typeName, rows: rows)
            return
        }
        if typeName.hasPrefix("Array(") {
            try skipArrayBody(typeName: typeName, rows: rows)
            return
        }
        if typeName.hasPrefix("Nullable(") {
            try skipNullableBody(typeName: typeName, rows: rows)
            return
        }
        if typeName.hasPrefix("Map(") {
            try skipMapBody(typeName: typeName, rows: rows)
            return
        }
        if typeName.hasPrefix("Tuple(") {
            let elements = try ClickHouseTupleTypeSplitter.split(typeName: typeName)
            for element in elements {
                try skipColumnBodyAfterPrefix(typeName: element.type, rows: rows)
            }
            return
        }
        if typeName.hasPrefix("Variant(") {
            try skipVariantBody(typeName: typeName, rows: rows)
            return
        }
        if typeName == "Dynamic" || typeName.hasPrefix("Dynamic(") {
            try skipDynamicBody(rows: rows)
            return
        }
        if typeName == "JSON" || typeName.hasPrefix("JSON(") || typeName.hasPrefix("Object(") {
            try skipJSONBody(rows: rows)
            return
        }
        if typeName.hasPrefix("AggregateFunction(") {
            try skipAggregateFunctionBody(typeName: typeName, rows: rows)
            return
        }
        let byteCount = try Self.columnByteWidth(typeName: typeName, rows: rows)
        if byteCount >= 0 {
            try skipBytes(byteCount)
            return
        }
        try skipStringRows(rows: rows)
    }

    // Tight loop variant of "skip N length-prefixed strings". Snapshots
    // the storage base pointer once per recv refill and iterates over
    // head/tail in raw integer arithmetic. The standard readUVarInt +
    // skipBytes loop went through ARC on the storage class and triggered
    // a class-property exclusivity check per row.
    @inline(__always)
    private func skipStringRows(rows: Int) throws(ClickHouseError) {
        var remaining = rows
        while remaining > 0 {
            let storage = arena.owner
            var head = arena.head
            let tail = arena.tail
            let base = storage.base
            // Inner tight loop — process as many rows as possible from
            // the current arena window without a recv() refill.
            inner: while remaining > 0 {
                // Try to read one UVarInt length.
                let available = tail - head
                if available <= 0 { break inner }
                var length: UInt64 = 0
                var shift: UInt64 = 0
                var lengthBytes = 0
                let maxLengthBytes = min(available, ClickHouseWire.uvarintMaxBytes)
                while lengthBytes < maxLengthBytes {
                    let byte = (base + head + lengthBytes)[0]
                    if byte < 0x80 {
                        if lengthBytes == ClickHouseWire.uvarintMaxBytes - 1 && byte > 1 {
                            arena.head = head
                            throw .protocolError(stage: "uvarint", message: "overflow")
                        }
                        length |= UInt64(byte) << shift
                        lengthBytes += 1
                        break
                    }
                    length |= UInt64(byte & 0x7F) << shift
                    shift += 7
                    lengthBytes += 1
                    if lengthBytes == ClickHouseWire.uvarintMaxBytes {
                        arena.head = head
                        throw .protocolError(stage: "uvarint", message: "overflow")
                    }
                }
                // If we did not terminate (top bit of last byte still set), refill.
                if lengthBytes == maxLengthBytes && maxLengthBytes < ClickHouseWire.uvarintMaxBytes {
                    break inner
                }
                // A String value longer than Int is impossible and would trap
                // the unchecked conversion; the window comparison is written
                // as a subtraction so `lengthBytes + lengthInt` can never
                // overflow either.
                guard let lengthInt = Int(exactly: length) else {
                    arena.head = head
                    throw .protocolError(stage: "decoder.string", message: "string length \(length) exceeds Int range")
                }
                if lengthInt > (tail - head) - lengthBytes {
                    break inner
                }
                head += lengthBytes + lengthInt
                remaining -= 1
            }
            arena.head = head
            if remaining > 0 {
                try fillMore(minBytes: 1)
            }
        }
    }

    // LC(T) body layout when rows > 0:
    //   UInt64 serializationType (key width in low byte + flags)
    //   UInt64 dictionarySize
    //   ... dictionarySize values of inner T encoded
    //   UInt64 indicesCount (= rows)
    //   ... indicesCount values of width keyWidth bytes
    //
    // When rows == 0, no bytes are emitted.
    // A LowCardinality dictionary is serialized as its inner type's values
    // directly. For LowCardinality(Nullable(T)) ClickHouse stores the inner
    // T values with no per-value null mask (the NULL is dictionary index 0),
    // so reading the dictionary as a Nullable column would consume phantom
    // mask bytes and desync the stream. The String/FixedString/fixed-width
    // inners the skip and copy paths handle are dense; reject a Nullable
    // inner with a clear error instead of misparsing it.
    private func skipLowCardinalityBody(typeName: String, rows: Int) throws(ClickHouseError) {
        if rows == 0 { return }
        let inner = innerType(typeName: typeName, prefix: "LowCardinality(")
        // See copyLowCardinalityColumnBody: a Nullable inner's dictionary is
        // the base type T on the wire, so skip it as the base type rather than
        // aborting mid-block.
        let dictionaryInner = inner.hasPrefix("Nullable(") ? innerType(typeName: inner, prefix: "Nullable(") : inner
        let serializationType = try readFixedInt(UInt64.self)
        let keyWidth = ClickHouseLowCardinalityWire.keyWidth(serializationType: serializationType)
        let dictionarySize = try readFixedInt(UInt64.self)
        let dictionaryRows = try boundedByteProduct(dictionarySize, width: 1, stage: "decoder.lowCardinality")
        try skipColumnBodyAfterPrefix(typeName: dictionaryInner, rows: dictionaryRows)
        let indicesCount = try readFixedInt(UInt64.self)
        try skipBytes(boundedByteProduct(indicesCount, width: keyWidth, stage: "decoder.lowCardinality"))
    }

    // Converts a server-supplied element count times a per-element width to
    // an Int byte total, rejecting both an out-of-Int count and a product
    // that overflows — the unchecked Int(UInt64) conversion or Int
    // multiplication would otherwise trap and crash the client.
    private func boundedByteProduct(_ count: UInt64, width: Int, stage: String) throws(ClickHouseError) -> Int {
        let (product, overflow) = count.multipliedReportingOverflow(by: UInt64(width))
        guard !overflow, let bytes = Int(exactly: product) else {
            throw .protocolError(stage: stage, message: "element count \(count) times width \(width) overflows")
        }
        return bytes
    }

    // A server-supplied Variant/Dynamic member count converted to Int. The
    // unchecked Int(UInt64) conversion would trap on a value above Int; the
    // member-reading loop self-limits against the wire, so only the count
    // conversion needs guarding (callers cap the reserveCapacity).
    private func boundedMemberCount(_ raw: UInt64, stage: String) throws(ClickHouseError) -> Int {
        guard let count = Int(exactly: raw) else {
            throw .protocolError(stage: stage, message: "member count \(raw) exceeds Int range")
        }
        return count
    }

    // Array(T) body layout:
    //   UInt64[rows] offsets (cumulative end indices into inner element list)
    //   inner column with totalElements rows (= last offset, or 0 if rows == 0)
    private func skipArrayBody(typeName: String, rows: Int) throws(ClickHouseError) {
        let inner = innerType(typeName: typeName, prefix: "Array(")
        var totalElements: UInt64 = 0
        for index in 0..<rows {
            let value = try readFixedInt(UInt64.self)
            if index == rows - 1 {
                totalElements = value
            }
        }
        try skipColumnBodyAfterPrefix(typeName: inner, rows: boundedByteProduct(totalElements, width: 1, stage: "decoder.array"))
    }

    // Nullable(T) body layout:
    //   UInt8[rows] null map
    //   inner column with rows values
    private func skipNullableBody(typeName: String, rows: Int) throws(ClickHouseError) {
        let inner = innerType(typeName: typeName, prefix: "Nullable(")
        try skipBytes(rows)
        try skipColumnBodyAfterPrefix(typeName: inner, rows: rows)
    }

    // Map(K, V) body layout: same as Array(Tuple(K, V)):
    //   UInt64[rows] offsets
    //   K column with totalElements rows
    //   V column with totalElements rows
    private func skipMapBody(typeName: String, rows: Int) throws(ClickHouseError) {
        let inner = innerType(typeName: typeName, prefix: "Map(")
        let (keyType, valueType) = Self.splitMapInner(inner)
        var totalElements: UInt64 = 0
        for index in 0..<rows {
            let value = try readFixedInt(UInt64.self)
            if index == rows - 1 {
                totalElements = value
            }
        }
        let elementRows = try boundedByteProduct(totalElements, width: 1, stage: "decoder.map")
        try skipColumnBodyAfterPrefix(typeName: keyType, rows: elementRows)
        try skipColumnBodyAfterPrefix(typeName: valueType, rows: elementRows)
    }

    // Variant(T0, T1, ...) body layout:
    //   UInt64 basic-discriminators mode prefix (0)
    //   UInt8[rows] discriminators (member index, 255 = NULL)
    //   each member's sub-column with its present-row count
    private func skipVariantBody(typeName: String, rows: Int) throws(ClickHouseError) {
        if rows == 0 { return }
        let members = try ClickHouseTupleTypeSplitter.split(typeName: variantAsTuple(typeName))
        _ = try readFixedInt(UInt64.self)
        try ensureBytes(rows)
        var counts = [Int](repeating: 0, count: members.count)
        // A discriminator (other than the 255 NULL marker) must index a real
        // member; a hostile server can send one past the end, which would
        // crash the unchecked `counts[discriminator]` subscript. Capture it
        // and throw outside the non-throwing read closure.
        var outOfRange = -1
        arena.withReadPointer { base, _ in
            let discriminators = UnsafeBufferPointer(start: base, count: rows)
            for index in 0..<rows {
                let discriminator = Int(discriminators[index])
                if discriminator == 255 { continue }
                if discriminator >= counts.count {
                    outOfRange = discriminator
                    continue
                }
                counts[discriminator] += 1
            }
        }
        arena.advanceHead(by: rows)
        if outOfRange >= 0 {
            throw .protocolError(stage: "decoder.variant", message: "discriminator \(outOfRange) out of member range \(members.count)")
        }
        for index in members.indices {
            try skipColumnBodyAfterPrefix(typeName: members[index].type, rows: counts[index])
        }
    }

    // Dynamic body: structure-version prefix, uvarint max-types, uvarint
    // member count, member type-name strings, then an embedded Variant
    // body. Reads the structure prefix to learn the sub-column types, then
    // skips the embedded Variant. Per-member counts align ascending
    // distinct present discriminators to member positions.
    private func skipDynamicBody(rows: Int) throws(ClickHouseError) {
        if rows == 0 { return }
        let structureVersion = try readFixedInt(UInt64.self)
        if structureVersion == 1 {
            _ = try readUVarInt()
        }
        let memberCount = try readUVarInt()
        let memberCountInt = try boundedMemberCount(memberCount, stage: "decoder.dynamic")
        var memberTypes: [String] = []
        memberTypes.reserveCapacity(Swift.min(memberCountInt, 64))
        for _ in 0..<memberCountInt {
            memberTypes.append(try readString())
        }
        _ = try readFixedInt(UInt64.self)
        try ensureBytes(rows)
        var rawDiscriminators = [UInt8](repeating: 0, count: rows)
        arena.withReadPointer { base, _ in
            let discriminators = UnsafeBufferPointer(start: base, count: rows)
            for index in 0..<rows { rawDiscriminators[index] = discriminators[index] }
        }
        arena.advanceHead(by: rows)
        let counts = memberPresentCounts(rawDiscriminators, memberCount: memberCountInt)
        for index in memberTypes.indices {
            try skipColumnBodyAfterPrefix(typeName: memberTypes[index], rows: counts[index])
        }
    }

    // JSON body (CH >= 24.10 dynamic JSON): a length-prefixed binary
    // payload per row. Each row begins with a UVarInt giving total
    // payload byte length, followed by that many bytes. This is the
    // minimum-viable skipper; full structural decode is not needed for
    // the bench, which never SELECTs JSON columns in the floor suite.
    private func skipJSONBody(rows: Int) throws(ClickHouseError) {
        for _ in 0..<rows {
            let length = try readUVarInt()
            try skipBytes(boundedByteProduct(length, width: 1, stage: "decoder.json"))
        }
    }

    private func innerType(typeName: String, prefix: String) -> String {
        let start = typeName.index(typeName.startIndex, offsetBy: prefix.count)
        let end = typeName.index(before: typeName.endIndex)
        return String(typeName[start..<end])
    }

    // Splits `K, V` into (K, V) respecting nesting. Map(K, V) where
    // K or V are themselves composite would have parentheses; we walk
    // depth and split at the top-level comma.
    static func splitMapInner(_ inner: String) -> (String, String) {
        let segments = ClickHouseTypeArgumentSplitter.topLevel(inner).segments
        guard segments.count >= 2 else { return (inner, "") }
        let value = String(segments[1].drop(while: { $0 == " " }))
        return (segments[0], value)
    }

    private func drainBlockPacket(revision: UInt64, consume: (Int, [String], [String]) throws -> Void) throws(ClickHouseError) -> Int {
        _ = try readString()
        let prologue = try parsePrologue()
        var names: [String] = []
        var types: [String] = []
        names.reserveCapacity(prologue.columnCount)
        types.reserveCapacity(prologue.columnCount)
        for _ in 0..<prologue.columnCount {
            let header = try parseColumnHeader(revision: revision)
            let expandedType = ClickHouseGeoTypeName.expand(header.type)
            names.append(header.name)
            types.append(expandedType)
            try skipColumnBody(typeName: expandedType, rows: prologue.rowCount)
        }
        if prologue.rowCount > 0 {
            do {
                try consume(prologue.rowCount, names, types)
            } catch let error as ClickHouseError {
                throw error
            } catch {
                throw .protocolError(stage: "drainBlockPacket consume", message: "\(error)")
            }
        }
        arena.compact()
        return prologue.rowCount
    }

    private func extractStringsBlockPacket(revision: UInt64, consume: (Int, [String], [String], [[UInt8]]) throws -> Void) throws(ClickHouseError) -> Int {
        _ = try readString()
        let prologue = try parsePrologue()
        var names: [String] = []
        var types: [String] = []
        var bodies: [[UInt8]] = []
        names.reserveCapacity(prologue.columnCount)
        types.reserveCapacity(prologue.columnCount)
        bodies.reserveCapacity(prologue.columnCount)
        for _ in 0..<prologue.columnCount {
            let header = try parseColumnHeader(revision: revision)
            let expandedType = ClickHouseGeoTypeName.expand(header.type)
            names.append(header.name)
            types.append(expandedType)
            var body: [UInt8] = []
            if expandedType == "String" {
                try copyStringColumnBody(rows: prologue.rowCount, into: &body)
            } else if expandedType.hasPrefix("FixedString(") {
                let width = try ClickHouseCodableDecoder.parseFixedStringLength(typeName: expandedType)
                let byteCount = try boundedByteProduct(UInt64(prologue.rowCount), width: width, stage: "decoder.fixedString")
                try copyFixedBytes(byteCount: byteCount, into: &body)
            } else {
                try skipColumnBody(typeName: expandedType, rows: prologue.rowCount)
            }
            bodies.append(body)
        }
        if prologue.rowCount > 0 {
            do {
                try consume(prologue.rowCount, names, types, bodies)
            } catch let error as ClickHouseError {
                throw error
            } catch {
                throw .protocolError(stage: "extractStringsBlockPacket consume", message: "\(error)")
            }
        }
        arena.compact()
        return prologue.rowCount
    }

    private func copyStringColumnBody(rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        for _ in 0..<rows {
            let length = try readUVarInt()
            let count = try boundedByteProduct(length, width: 1, stage: "decoder.string")
            try ensureBytes(count)
            arena.withReadPointer { base, _ in
                let buffer = UnsafeBufferPointer(start: base, count: count)
                ClickHouseWire.writeUVarInt(length, into: &output)
                output.append(contentsOf: buffer)
            }
            arena.advanceHead(by: count)
        }
    }

    private func copyFixedBytes(byteCount: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        if byteCount <= 0 { return }
        try ensureBytes(byteCount)
        arena.withReadPointer { base, _ in
            let buffer = UnsafeBufferPointer(start: base, count: byteCount)
            output.append(contentsOf: buffer)
        }
        arena.advanceHead(by: byteCount)
    }

    private func skipBytes(_ count: Int) throws(ClickHouseError) {
        if count <= 0 { return }
        try ensureBytes(count)
        arena.advanceHead(by: count)
    }

    private func readBlockPacket(revision: UInt64, consume: (ClickHouseBlock, UnsafeRawBufferPointer) throws -> Void) throws(ClickHouseError) -> Int {
        _ = try readString() // table name
        let prologue = try parsePrologue()
        var names: [String] = []
        var types: [String] = []
        names.reserveCapacity(prologue.columnCount)
        types.reserveCapacity(prologue.columnCount)
        // We materialise per-column bodies into one shared buffer so the
        // consumer sees a contiguous slice. This is the floor — a
        // higher-throughput path would deliver per-column slices in
        // place; the bench wrapper will measure that variant separately.
        var combined: [UInt8] = []
        var combinedRanges: [Range<Int>] = []
        combinedRanges.reserveCapacity(prologue.columnCount)
        for _ in 0..<prologue.columnCount {
            let header = try parseColumnHeader(revision: revision)
            let expandedType = ClickHouseGeoTypeName.expand(header.type)
            names.append(header.name)
            types.append(expandedType)
            let start = combined.count
            try copyColumnBody(typeName: expandedType, rows: prologue.rowCount, into: &combined)
            combinedRanges.append(start..<combined.count)
        }
        let block = ClickHouseBlock(
            rowCount: prologue.rowCount,
            columnCount: prologue.columnCount,
            columnNames: names,
            columnTypes: types,
            bodyStart: 0,
            bodyLength: combined.count
        )
        if prologue.rowCount > 0 {
            do {
                try combined.withUnsafeBytes { rawBuffer in
                    try consume(block, rawBuffer)
                }
            } catch let error as ClickHouseError {
                throw error
            } catch {
                throw .protocolError(stage: "readBlockPacket consume", message: "\(error)")
            }
        }
        arena.compact()
        return prologue.rowCount
    }

    private func copyColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        // Nullable(T) on the wire is `rowCount` null-mask bytes
        // followed by `rowCount` inner-T values. We preserve this exact
        // layout in the output so the typed Codable decoder can lift
        // mask + inner column directly.
        if typeName.hasPrefix("Nullable(") {
            try ensureBytes(rows)
            arena.withReadPointer { base, _ in
                let buffer = UnsafeBufferPointer(start: base, count: rows)
                output.append(contentsOf: buffer)
            }
            arena.advanceHead(by: rows)
            let inner = String(typeName.dropFirst("Nullable(".count).dropLast())
            try copyColumnBody(typeName: inner, rows: rows, into: &output)
            return
        }
        if typeName.hasPrefix("Array(") {
            try copyArrayColumnBody(typeName: typeName, rows: rows, into: &output)
            return
        }
        if typeName.hasPrefix("LowCardinality(") {
            try copyLowCardinalityColumnBody(typeName: typeName, rows: rows, into: &output)
            return
        }
        if typeName.hasPrefix("Tuple(") {
            try copyTupleColumnBody(typeName: typeName, rows: rows, into: &output)
            return
        }
        if typeName.hasPrefix("Map(") {
            try copyMapColumnBody(typeName: typeName, rows: rows, into: &output)
            return
        }
        if typeName.hasPrefix("Variant(") {
            try copyVariantColumnBody(typeName: typeName, rows: rows, into: &output)
            return
        }
        if typeName == "Dynamic" || typeName.hasPrefix("Dynamic(") {
            try copyDynamicColumnBody(rows: rows, into: &output)
            return
        }
        if typeName.hasPrefix("AggregateFunction(") {
            try copyAggregateFunctionColumnBody(typeName: typeName, rows: rows, into: &output)
            return
        }
        // The native JSON type is a length-prefixed binary payload per row,
        // the same on-wire layout as a String column. We do not structurally
        // decode it, but copying its body here keeps the block fully read so
        // the typed decoder rejects the unsupported type at a clean packet
        // boundary instead of leaving unread bytes that desync the connection.
        if typeName == "JSON" || typeName.hasPrefix("JSON(") || typeName.hasPrefix("Object(") {
            try copyLengthPrefixedRows(rows: rows, into: &output)
            return
        }
        let byteCount = try Self.columnByteWidth(typeName: typeName, rows: rows)
        if byteCount >= 0 {
            try ensureBytes(byteCount)
            arena.withReadPointer { base, _ in
                let buffer = UnsafeBufferPointer(start: base, count: byteCount)
                output.append(contentsOf: buffer)
            }
            arena.advanceHead(by: byteCount)
            return
        }
        // Variable-width (String column). Walk row-by-row.
        try copyLengthPrefixedRows(rows: rows, into: &output)
    }

    // Copies `rows` length-prefixed values (UVarInt length, then that many
    // bytes) verbatim into `output`, the layout shared by String and the
    // native JSON column bodies.
    // A length-prefixed column body (String or native JSON) is a contiguous
    // run of `[UVarInt length, bytes]` records. The previous per-row loop read
    // each length, re-wrote it, and appended the bytes through `withReadPointer`
    // — a class-property exclusivity check and bound recheck on every row that
    // dominated a string-heavy read. This mirrors the tight `skipStringRows`
    // scan (snapshot the arena pointer, no per-row ARC) and bulk-copies each
    // refill window's worth of complete records in a single append. The copy
    // happens BEFORE the next `fillMore`, because that refill may compact the
    // arena and discard the bytes already walked — so the run cannot be copied
    // in one append after the whole scan, only window by window.
    private func copyLengthPrefixedRows(rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        var remaining = rows
        while remaining > 0 {
            let storage = arena.owner
            var head = arena.head
            let windowStart = head
            let tail = arena.tail
            let base = storage.base
            inner: while remaining > 0 {
                let available = tail - head
                if available <= 0 { break inner }
                var length: UInt64 = 0
                var shift: UInt64 = 0
                var lengthBytes = 0
                let maxLengthBytes = min(available, ClickHouseWire.uvarintMaxBytes)
                while lengthBytes < maxLengthBytes {
                    let byte = (base + head + lengthBytes)[0]
                    if byte < 0x80 {
                        if lengthBytes == ClickHouseWire.uvarintMaxBytes - 1 && byte > 1 {
                            arena.head = head
                            throw .protocolError(stage: "uvarint", message: "overflow")
                        }
                        length |= UInt64(byte) << shift
                        lengthBytes += 1
                        break
                    }
                    length |= UInt64(byte & 0x7F) << shift
                    shift += 7
                    lengthBytes += 1
                    if lengthBytes == ClickHouseWire.uvarintMaxBytes {
                        arena.head = head
                        throw .protocolError(stage: "uvarint", message: "overflow")
                    }
                }
                if lengthBytes == maxLengthBytes && maxLengthBytes < ClickHouseWire.uvarintMaxBytes {
                    break inner
                }
                guard let lengthInt = Int(exactly: length) else {
                    arena.head = head
                    throw .protocolError(stage: "decoder.string", message: "string length \(length) exceeds Int range")
                }
                if lengthInt > (tail - head) - lengthBytes {
                    break inner
                }
                head += lengthBytes + lengthInt
                remaining -= 1
            }
            if head > windowStart {
                output.append(contentsOf: UnsafeBufferPointer(start: base + windowStart, count: head - windowStart))
            }
            arena.head = head
            if remaining > 0 {
                try fillMore(minBytes: 1)
            }
        }
    }

    // Array(T) body: rowCount cumulative UInt64 offsets, then the inner
    // column with totalElements (= last offset) rows. We copy the offsets
    // verbatim and recurse for the flattened inner body so the typed
    // Codable decoder can lift offsets + inner directly.
    private func copyArrayColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        let inner = innerType(typeName: typeName, prefix: "Array(")
        if inner.hasPrefix("LowCardinality(") {
            try copyArrayOfLowCardinalityColumnBody(innerLowCardinality: inner, rows: rows, into: &output)
            return
        }
        var totalElementsRaw: UInt64 = 0
        for index in 0..<rows {
            let value = try readFixedInt(UInt64.self)
            ClickHouseWire.writeFixedInt(value, into: &output)
            if index == rows - 1 { totalElementsRaw = value }
        }
        let totalElements = try boundedByteProduct(totalElementsRaw, width: 1, stage: "decoder.array")
        try copyColumnBody(typeName: inner, rows: totalElements, into: &output)
    }

    // Array(LowCardinality(T)) hoists the LowCardinality KeysSerializationVersion
    // ahead of the array offsets (a standalone LowCardinality keeps the version
    // contiguous with its dictionary body). The dictionary bulk follows the
    // offsets only when the array carries at least one element; an all-empty
    // column stops after the version and the single zero offset, so reading the
    // dictionary header there would block waiting for bytes the server never
    // sends.
    private func copyArrayOfLowCardinalityColumnBody(innerLowCardinality: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        guard rows > 0 else { return }
        let version = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(version, into: &output)
        var totalElementsRaw: UInt64 = 0
        for index in 0..<rows {
            let value = try readFixedInt(UInt64.self)
            ClickHouseWire.writeFixedInt(value, into: &output)
            if index == rows - 1 { totalElementsRaw = value }
        }
        let totalElements = try boundedByteProduct(totalElementsRaw, width: 1, stage: "decoder.array")
        guard totalElements > 0 else { return }
        let lowCardinalityInner = innerType(typeName: innerLowCardinality, prefix: "LowCardinality(")
        try copyLowCardinalityBulk(lowCardinalityInner: lowCardinalityInner, into: &output)
    }

    // LowCardinality(T) body: KeysSerializationVersion, serialization type
    // (key width in the low byte), dictionary size, the dictionary values
    // in the inner type's body format, the index count, then index count
    // indices at the chosen width. All copied verbatim for the decoder.
    private func copyLowCardinalityColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        if rows == 0 { return }
        let inner = innerType(typeName: typeName, prefix: "LowCardinality(")
        // LowCardinality(Nullable(T)) serializes its dictionary as the base
        // type T (index 0 is the NULL placeholder), the same byte layout as
        // LowCardinality(T). Read the dictionary as the base type so the block
        // is fully copied; the typed decoder still rejects the Nullable inner,
        // but at a clean boundary rather than this copy aborting mid-block and
        // desyncing the connection for the next request.
        let version = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(version, into: &output)
        try copyLowCardinalityBulk(lowCardinalityInner: inner, into: &output)
    }

    // The dictionary bulk of a LowCardinality column: serialization type, the
    // dictionary size and its values, the index count, then the indices at the
    // serialization type's key width. The KeysSerializationVersion that precedes
    // it is read by the caller (contiguous for a standalone column, hoisted
    // ahead of the offsets for Array(LowCardinality)).
    private func copyLowCardinalityBulk(lowCardinalityInner: String, into output: inout [UInt8]) throws(ClickHouseError) {
        let dictionaryInner = lowCardinalityInner.hasPrefix("Nullable(") ? innerType(typeName: lowCardinalityInner, prefix: "Nullable(") : lowCardinalityInner
        let serializationType = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(serializationType, into: &output)
        let keyWidth = ClickHouseLowCardinalityWire.keyWidth(serializationType: serializationType)
        let dictionarySize = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(dictionarySize, into: &output)
        try copyColumnBody(typeName: dictionaryInner, rows: boundedByteProduct(dictionarySize, width: 1, stage: "decoder.lowCardinality"), into: &output)
        let indicesCount = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(indicesCount, into: &output)
        let indexBytes = try boundedByteProduct(indicesCount, width: keyWidth, stage: "decoder.lowCardinality")
        try ensureBytes(indexBytes)
        arena.withReadPointer { base, _ in
            output.append(contentsOf: UnsafeBufferPointer(start: base, count: indexBytes))
        }
        arena.advanceHead(by: indexBytes)
    }

    // Tuple(T1, T2, ...) body: each element column serialized in full
    // sequentially, every element carrying `rows` rows, with no offsets
    // or delimiters between elements. We recurse copyColumnBody for each
    // element type so the typed Codable decoder can re-split and lift the
    // inner columns directly. Element names in the type string (named
    // tuples) are metadata only and do not affect the byte layout.
    private func copyTupleColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        let elements = try ClickHouseTupleTypeSplitter.split(typeName: typeName)
        for element in elements {
            try copyColumnBody(typeName: element.type, rows: rows, into: &output)
        }
    }

    // Map(K, V) body: same layout as Array(Tuple(K, V)). rowCount
    // cumulative UInt64 entry-count offsets, then the K column with
    // totalElements (= last offset) rows, then the V column with the
    // same totalElements rows. We copy the offsets verbatim and recurse
    // for the flattened key and value bodies so the typed Codable decoder
    // can lift offsets + K + V directly.
    private func copyMapColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        guard rows > 0 else { return }
        let inner = innerType(typeName: typeName, prefix: "Map(")
        let (keyType, valueType) = Self.splitMapInner(inner)
        // A LowCardinality key or value hoists its KeysSerializationVersion ahead
        // of the map offsets, in key-then-value order, the same as Array
        // (LowCardinality). Reading the version inline (with the dictionary body)
        // would mis-frame the block and desync the connection.
        try copyHoistedLowCardinalityVersion(typeName: keyType, into: &output)
        try copyHoistedLowCardinalityVersion(typeName: valueType, into: &output)
        var totalElementsRaw: UInt64 = 0
        for index in 0..<rows {
            let value = try readFixedInt(UInt64.self)
            ClickHouseWire.writeFixedInt(value, into: &output)
            if index == rows - 1 { totalElementsRaw = value }
        }
        let totalElements = try boundedByteProduct(totalElementsRaw, width: 1, stage: "decoder.map")
        try copyMapSideColumnBody(typeName: keyType, totalElements: totalElements, into: &output)
        try copyMapSideColumnBody(typeName: valueType, totalElements: totalElements, into: &output)
    }

    private func copyHoistedLowCardinalityVersion(typeName: String, into output: inout [UInt8]) throws(ClickHouseError) {
        guard typeName.hasPrefix("LowCardinality(") else { return }
        let version = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(version, into: &output)
    }

    // A map key or value column. A LowCardinality side's version is hoisted ahead
    // of the offsets, so only its dictionary bulk follows here — and an all-empty
    // map omits that bulk entirely. A LowCardinality nested inside another type on
    // a map side (Array(LowCardinality(...)), Tuple(... LowCardinality ...)) hoists
    // its version on a different schedule that this walker does not model; copying
    // it as a plain column would mis-frame the block and hang the connection
    // waiting for bytes that never arrive, so it is rejected at a clean boundary.
    private func copyMapSideColumnBody(typeName: String, totalElements: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        guard typeName.hasPrefix("LowCardinality(") else {
            guard !typeName.contains("LowCardinality(") else {
                throw .protocolError(stage: "decoder.map", message: "Map side \(typeName) nests LowCardinality inside another type, which is not supported; select the inner column separately")
            }
            try copyColumnBody(typeName: typeName, rows: totalElements, into: &output)
            return
        }
        guard totalElements > 0 else { return }
        let lowCardinalityInner = innerType(typeName: typeName, prefix: "LowCardinality(")
        try copyLowCardinalityBulk(lowCardinalityInner: lowCardinalityInner, into: &output)
    }

    // Variant(T0, T1, ...) body: an 8-byte basic-discriminators mode
    // prefix (always 0), then one discriminator byte per row (the member's
    // alphabetical index, 255 = NULL), then each member's sub-column in
    // member-index order carrying only the present rows' values. We copy
    // the mode prefix and discriminator array verbatim, count how many rows
    // select each member, and recurse copyColumnBody for each member with
    // that present count so the typed Codable decoder can scatter the
    // sub-columns back per row.
    private func copyVariantColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        if rows == 0 { return }
        let members = try ClickHouseTupleTypeSplitter.split(typeName: variantAsTuple(typeName))
        let modePrefix = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(modePrefix, into: &output)
        try ensureBytes(rows)
        var counts = [Int](repeating: 0, count: members.count)
        var outOfRange = -1
        arena.withReadPointer { base, _ in
            let discriminators = UnsafeBufferPointer(start: base, count: rows)
            output.append(contentsOf: discriminators)
            for index in 0..<rows {
                let discriminator = Int(discriminators[index])
                if discriminator == 255 { continue }
                if discriminator >= counts.count {
                    outOfRange = discriminator
                    continue
                }
                counts[discriminator] += 1
            }
        }
        arena.advanceHead(by: rows)
        if outOfRange >= 0 {
            throw .protocolError(stage: "decoder.variant", message: "discriminator \(outOfRange) out of member range \(members.count)")
        }
        for index in members.indices {
            try copyColumnBody(typeName: members[index].type, rows: counts[index], into: &output)
        }
    }

    private func variantAsTuple(_ typeName: String) -> String {
        "Tuple(\(innerType(typeName: typeName, prefix: "Variant(")))"
    }

    // Dynamic body: an 8-byte structure-version prefix, a uvarint
    // max-dynamic-types limit, a uvarint member count, that many member
    // type-name strings (canonical sorted order), then an embedded Variant
    // body. The structure prefix is copied verbatim, the member type names
    // are read to know each sub-column's type, and the embedded Variant
    // body is copied. ClickHouse can emit non-contiguous discriminator
    // values even on a fresh insert, so the per-member present count is
    // derived by aligning the ascending distinct present discriminators to
    // the member list positions, not by assuming discriminator == member
    // index.
    private func copyDynamicColumnBody(rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        if rows == 0 { return }
        let structureVersion = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(structureVersion, into: &output)
        if structureVersion == 1 {
            let maxTypes = try readUVarInt()
            ClickHouseWire.writeUVarInt(maxTypes, into: &output)
        }
        let memberCount = try readUVarInt()
        ClickHouseWire.writeUVarInt(memberCount, into: &output)
        let memberCountInt = try boundedMemberCount(memberCount, stage: "decoder.dynamic")
        var memberTypes: [String] = []
        memberTypes.reserveCapacity(Swift.min(memberCountInt, 64))
        for _ in 0..<memberCountInt {
            let name = try readString()
            ClickHouseWire.writeString(name, into: &output)
            memberTypes.append(name)
        }
        let modePrefix = try readFixedInt(UInt64.self)
        ClickHouseWire.writeFixedInt(modePrefix, into: &output)
        let counts = try copyDynamicDiscriminators(rows: rows, memberCount: memberCountInt, into: &output)
        for index in memberTypes.indices {
            try copyColumnBody(typeName: memberTypes[index], rows: counts[index], into: &output)
        }
    }

    // AggregateFunction column body is the per-row serialized states
    // concatenated with no framing. The byte count is rows * the
    // fixed per-row state width derived from the signature; signatures
    // whose state width SwiftDX cannot determine throw here so the read
    // never consumes the wrong number of bytes.
    private func copyAggregateFunctionColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(ClickHouseError) {
        if rows == 0 { return }
        let signature = String(typeName.dropFirst("AggregateFunction(".count).dropLast())
        let width = try ClickHouseAggregateStateWidth.width(signature: signature)
        try copyFixedBytes(byteCount: boundedByteProduct(UInt64(rows), width: width, stage: "decoder.aggregateFunction"), into: &output)
    }

    private func skipAggregateFunctionBody(typeName: String, rows: Int) throws(ClickHouseError) {
        if rows == 0 { return }
        let signature = String(typeName.dropFirst("AggregateFunction(".count).dropLast())
        let width = try ClickHouseAggregateStateWidth.width(signature: signature)
        try skipBytes(boundedByteProduct(UInt64(rows), width: width, stage: "decoder.aggregateFunction"))
    }

    private func copyDynamicDiscriminators(rows: Int, memberCount: Int, into output: inout [UInt8]) throws(ClickHouseError) -> [Int] {
        try ensureBytes(rows)
        var rawDiscriminators = [UInt8](repeating: 0, count: rows)
        arena.withReadPointer { base, _ in
            let discriminators = UnsafeBufferPointer(start: base, count: rows)
            output.append(contentsOf: discriminators)
            for index in 0..<rows { rawDiscriminators[index] = discriminators[index] }
        }
        arena.advanceHead(by: rows)
        return memberPresentCounts(rawDiscriminators, memberCount: memberCount)
    }

    private func memberPresentCounts(_ raw: [UInt8], memberCount: Int) -> [Int] {
        var distinct: [UInt8] = []
        for value in raw where value != 255 && !distinct.contains(value) {
            distinct.append(value)
        }
        distinct.sort()
        var position = [Int](repeating: -1, count: 256)
        for index in distinct.indices where index < memberCount {
            position[Int(distinct[index])] = index
        }
        var counts = [Int](repeating: 0, count: memberCount)
        for value in raw where value != 255 {
            let memberIndex = position[Int(value)]
            if memberIndex >= 0 { counts[memberIndex] += 1 }
        }
        return counts
    }

    static func columnByteWidth(typeName: String, rows: Int) throws(ClickHouseError) -> Int {
        let perRow = try columnWidthPerRow(typeName: typeName)
        if perRow < 0 { return -1 }
        // A hostile or corrupt server can declare a row count that, times the
        // per-row width, exceeds Int — the unchecked product would trap.
        let (total, overflow) = rows.multipliedReportingOverflow(by: perRow)
        if overflow {
            throw .protocolError(stage: "columnByteWidth", message: "row count \(rows) times width \(perRow) overflows for \(typeName)")
        }
        return total
    }

    // Per-row byte width of a fixed-width column type, or -1 for the
    // variable-width String column. Keeps the row-count multiplication
    // (and its overflow check) out of the type switch.
    static func columnWidthPerRow(typeName: String) throws(ClickHouseError) -> Int {
        switch typeName {
        case "UInt8", "Int8", "Bool", "Nothing": return 1
        case "UInt16", "Int16", "Date", "BFloat16": return 2
        case "UInt32", "Int32", "Float32", "DateTime", "IPv4", "Date32", "Time": return 4
        case "UInt64", "Int64", "Float64": return 8
        case "UInt128", "Int128", "UUID", "IPv6": return 16
        case "UInt256", "Int256": return 32
        case "String": return -1
        default:
            if ClickHouseIntervalKind.isKindName(typeName) { return 8 }
            if typeName.hasPrefix("Enum8(") { return 1 }
            if typeName.hasPrefix("Enum16(") { return 2 }
            if typeName.hasPrefix("DateTime(") { return 4 }
            if typeName.hasPrefix("DateTime64(") { return 8 }
            if typeName.hasPrefix("Time64(") { return 8 }
            if typeName.hasPrefix("FixedString(") {
                return try ClickHouseCodableDecoder.parseFixedStringLength(typeName: typeName)
            }
            if typeName.hasPrefix("Decimal") {
                return try decimalByteWidth(typeName: typeName)
            }
            throw .protocolError(stage: "columnByteWidth", message: "unsupported column type \(typeName)")
        }
    }

    static func decimalByteWidth(typeName: String) throws(ClickHouseError) -> Int {
        if typeName.hasPrefix("Decimal32(") { return 4 }
        if typeName.hasPrefix("Decimal64(") { return 8 }
        if typeName.hasPrefix("Decimal128(") { return 16 }
        if typeName.hasPrefix("Decimal256(") { return 32 }
        if typeName.hasPrefix("Decimal(") {
            let inner = typeName.dropFirst("Decimal(".count)
            var precision = 0
            for byte in inner.utf8 {
                if byte < 0x30 || byte > 0x39 { break }
                precision = precision * 10 + Int(byte - 0x30)
                // ClickHouse Decimal precision is 1...76. Bounding the parse
                // here keeps a malformed or oversized type name from
                // overflowing the running total (a crash) or silently
                // wrapping through UInt8 to the wrong byte width.
                if precision > 76 {
                    throw .protocolError(stage: "decimalByteWidth", message: "Decimal precision out of range in \(typeName)")
                }
            }
            return ClickHouseDecimalWidth.bytes(forPrecision: UInt8(precision))
        }
        throw .protocolError(stage: "columnByteWidth", message: "unsupported column type \(typeName)")
    }

    private func readExceptionPacket(depth: Int = 0) throws(ClickHouseError) -> ClickHouseServerException {
        if depth >= 128 {
            throw .protocolError(stage: "exception", message: "nested server-exception chain exceeds 128 levels")
        }
        let code = try readFixedInt(Int32.self)
        let name = try readString()
        let message = try readString()
        let stackTrace = try readString()
        let hasNested = try readByte()
        var nested: [ClickHouseServerException] = []
        if hasNested != 0 {
            let inner = try readExceptionPacket(depth: depth + 1)
            nested.append(inner)
        }
        return ClickHouseServerException(
            code: code,
            name: name,
            message: message,
            stackTrace: stackTrace,
            nested: nested
        )
    }

    private func skipProgressPacket(revision: UInt64) throws(ClickHouseError) {
        _ = try readProgressPacket(revision: revision)
    }

    private func readProgressPacket(revision: UInt64) throws(ClickHouseError) -> ClickHouseProgress {
        let rows = try readUVarInt()
        let bytes = try readUVarInt()
        let totalRows = try readUVarInt()
        var totalBytes: UInt64 = 0
        if revision >= 54_463 { totalBytes = try readUVarInt() }
        var writtenRows: UInt64 = 0
        var writtenBytes: UInt64 = 0
        if revision >= 54_420 {
            writtenRows = try readUVarInt()
            writtenBytes = try readUVarInt()
        }
        var elapsed: UInt64 = 0
        if revision >= 54_460 { elapsed = try readUVarInt() }
        return ClickHouseProgress(
            rows: rows,
            bytes: bytes,
            totalRows: totalRows,
            totalBytes: totalBytes,
            writtenRows: writtenRows,
            writtenBytes: writtenBytes,
            elapsedNanoseconds: elapsed
        )
    }

    private func skipProfileInfoPacket(revision: UInt64) throws(ClickHouseError) {
        _ = try readProfileInfoPacket(revision: revision)
    }

    private func readProfileInfoPacket(revision: UInt64) throws(ClickHouseError) -> ClickHouseProfileInfo {
        let rows = try readUVarInt()
        let blocks = try readUVarInt()
        let bytes = try readUVarInt()
        let appliedLimit = try readByte() != 0
        let rowsBeforeLimit = try readUVarInt()
        let calculatedRowsBeforeLimit = try readByte() != 0
        var appliedAggregation = false
        var rowsBeforeAggregation: UInt64 = 0
        if revision >= 54_469 {
            appliedAggregation = try readByte() != 0
            rowsBeforeAggregation = try readUVarInt()
        }
        return ClickHouseProfileInfo(
            rows: rows,
            blocks: blocks,
            bytes: bytes,
            appliedLimit: appliedLimit,
            rowsBeforeLimit: rowsBeforeLimit,
            calculatedRowsBeforeLimit: calculatedRowsBeforeLimit,
            appliedAggregation: appliedAggregation,
            rowsBeforeAggregation: rowsBeforeAggregation
        )
    }

    @inline(__always)
    private func readByte() throws(ClickHouseError) -> UInt8 {
        try ensureBytes(1)
        let storage = arena.owner
        let value = (storage.base + arena.head)[0]
        arena.head += 1
        return value
    }

    @inline(__always)
    private func readFixedInt<T: FixedWidthInteger>(_ type: T.Type) throws(ClickHouseError) -> T {
        let size = MemoryLayout<T>.size
        try ensureBytes(size)
        let storage = arena.owner
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: storage.base + arena.head, count: size))
        }
        arena.head += size
        return T(littleEndian: value)
    }

    @inline(__always)
    private func readUVarInt() throws(ClickHouseError) -> UInt64 {
        let storage = arena.owner
        while true {
            let available = arena.tail - arena.head
            if available > 0 {
                let base = storage.base + arena.head
                // Fast path: try a 10-byte uvarint parse without the throw machinery.
                // Worst case is 10 bytes; if available < 10 we may still succeed on
                // a short value or fall through to the slow path on truncation.
                var value: UInt64 = 0
                var shift: UInt64 = 0
                var index = 0
                let cap = min(available, ClickHouseWire.uvarintMaxBytes)
                while index < cap {
                    let byte = base[index]
                    if byte < 0x80 {
                        if index == ClickHouseWire.uvarintMaxBytes - 1 && byte > 1 {
                            throw .protocolError(stage: "uvarint", message: "overflow")
                        }
                        value |= UInt64(byte) << shift
                        arena.head += index + 1
                        return value
                    }
                    value |= UInt64(byte & 0x7F) << shift
                    shift += 7
                    index += 1
                }
                if index == ClickHouseWire.uvarintMaxBytes {
                    throw .protocolError(stage: "uvarint", message: "overflow")
                }
            }
            try fillMore(minBytes: 1)
        }
    }

    private func readString() throws(ClickHouseError) -> String {
        while true {
            let outcome: ParseStringOutcome = arena.withReadPointer { base, available in
                do {
                    let parsed = try ClickHouseWire.readString(base: base, offset: 0, limit: available)
                    return .ready(value: parsed.0, consumed: parsed.1)
                } catch ClickHouseParseError.needsMoreBytes {
                    return .needsMoreBytes
                } catch ClickHouseParseError.malformed(let stage, let message) {
                    return .malformed(stage: stage, message: message)
                } catch {
                    return .malformed(stage: "string", message: "\(error)")
                }
            }
            switch outcome {
            case .ready(let value, let consumed):
                arena.advanceHead(by: consumed)
                return value
            case .needsMoreBytes:
                try fillMore(minBytes: 1)
            case .malformed(let stage, let message):
                throw .protocolError(stage: stage, message: message)
            }
        }
    }

    private func ensureBytes(_ count: Int) throws(ClickHouseError) {
        while arena.readable < count {
            try fillMore(minBytes: count - arena.readable)
        }
    }

    // recv() loop helper. A failed recv cannot be resumed: the server has
    // already begun streaming a result that a fresh socket could not pick
    // up mid-stream, so the current read must fail. Rather than reconnect
    // inline (which would block this caller in the unbounded always-retry
    // loop for the whole outage to surface an error it raises anyway), it
    // closes the dead socket and throws; the next sendQuery re-establishes
    // the connection lazily through sendAllWithReconnect. Two paths own
    // their own teardown and are left alone (see shouldTearDownSocketAfterRecvFailure):
    //  * -1 → `.socketIOFailed` with the captured errno.
    //  * 0 → `.unexpectedEOF` mid-stream.
    private func fillMore(minBytes: Int) throws(ClickHouseError) {
        arena.ensureFreeCapacity(max(minBytes, 4096))
        let storage = arena.owner
        var received = 0
        repeat {
            #if canImport(Darwin)
            received = Darwin.recv(socketHandle, storage.base + arena.tail, storage.capacity - arena.tail, 0)
            #else
            received = Glibc.recv(socketHandle, storage.base + arena.tail, storage.capacity - arena.tail, 0)
            #endif
        } while received < 0 && errno == EINTR
        if received < 0 {
            let capturedErrno = errno
            if shouldTearDownSocketAfterRecvFailure() { close() }
            throw .socketIOFailed(errno: capturedErrno, syscall: "recv")
        }
        if received == 0 {
            if shouldTearDownSocketAfterRecvFailure() { close() }
            throw .unexpectedEOF(bytesExpected: minBytes)
        }
        arena.tail += received
    }

    // A recv failure mid-stream leaves the socket unusable: the server's
    // in-flight result stream cannot be resumed on a fresh connection, so
    // the current operation must fail. Reconnecting inline here would not
    // rescue this query (it fails regardless) and, under the unbounded
    // always-retry policy, would block this caller in the reconnect loop
    // for the entire broker outage. Instead close the dead socket so the
    // NEXT operation's send-with-reconnect re-establishes it lazily, and
    // surface the I/O error now. Two paths own their own socket teardown
    // and must be left alone: an in-progress single-shot pingOnce probe,
    // and a recv that a timeout teardown already shut the socket for.
    private func shouldTearDownSocketAfterRecvFailure() -> Bool {
        if reconnectSuppressed { return false }
        if timeoutTeardownRequested.exchange(false, ordering: .acquiringAndReleasing) { return false }
        return true
    }

    // Send-with-reconnect entry point used by `sendQuery`. A query has
    // not yet had any server-side response begin streaming, so a
    // transient EPIPE / ECONNRESET on the send is safe to retry after a
    // reconnect. We attempt up to `reconnectionPolicy.maxAttempts` send
    // retries, each preceded by a fresh reconnect + handshake.
    private func sendAllWithReconnect(_ bytes: [UInt8]) throws(ClickHouseError) {
        do {
            try sendAllOnce(bytes)
            return
        } catch let firstError {
            if !shouldReconnect(after: firstError) {
                throw firstError
            }
            // Reconnect, then retry the send once. If the send fails
            // again, surface the latest error.
            try reconnect()
            try sendAllOnce(bytes)
        }
    }

    private func shouldReconnect(after error: ClickHouseError) -> Bool {
        switch error {
        case .socketIOFailed, .unexpectedEOF:
            return reconnectionPolicy.maxAttempts > 0
        case .connectionFailed, .protocolError, .queryFailed, .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            return false
        }
    }

    private enum SendOutcome {
        case completed
        case failed(ClickHouseError)
    }

    private func sendAllOnce(_ bytes: [UInt8]) throws(ClickHouseError) {
        var offset = 0
        let handle = socketHandle
        let totalCount = bytes.count
        let outcome: SendOutcome = bytes.withUnsafeBufferPointer { buffer -> SendOutcome in
            guard let base = buffer.baseAddress else { return .completed }
            while offset < totalCount {
                #if canImport(Darwin)
                let written = Darwin.send(handle, base + offset, totalCount - offset, 0)
                #else
                let written = Glibc.send(handle, base + offset, totalCount - offset, Int32(MSG_NOSIGNAL))
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    return .failed(.socketIOFailed(errno: errno, syscall: "send"))
                }
                if written == 0 {
                    return .failed(.unexpectedEOF(bytesExpected: totalCount - offset))
                }
                offset += written
            }
            return .completed
        }
        if case .failed(let error) = outcome { throw error }
    }

    // Sends two buffers as one contiguous write via writev, so the caller's
    // payload and a trailing marker leave in a single syscall without
    // concatenating them into a new buffer. Used by the INSERT path to emit
    // the data block and its empty terminator together, keeping them in one
    // segment so a partial-read peer cannot interleave the terminator with the
    // next request. Partial writes are handled by advancing past whichever
    // buffer the kernel has already drained.
    private func sendAllVectored(_ first: [UInt8], _ second: [UInt8]) throws(ClickHouseError) {
        let handle = socketHandle
        let outcome: SendOutcome = first.withUnsafeBufferPointer { firstBuffer -> SendOutcome in
            second.withUnsafeBufferPointer { secondBuffer -> SendOutcome in
                let firstCount = firstBuffer.count
                let secondCount = secondBuffer.count
                var firstOffset = 0
                var secondOffset = 0
                while firstOffset < firstCount || secondOffset < secondCount {
                    var vectors: [iovec] = []
                    if firstOffset < firstCount, let base = firstBuffer.baseAddress {
                        vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: base + firstOffset), iov_len: firstCount - firstOffset))
                    }
                    if secondOffset < secondCount, let base = secondBuffer.baseAddress {
                        vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: base + secondOffset), iov_len: secondCount - secondOffset))
                    }
                    let written = vectors.withUnsafeBufferPointer { vectorBuffer in
                        writev(handle, vectorBuffer.baseAddress, Int32(vectorBuffer.count))
                    }
                    if written < 0 {
                        if errno == EINTR { continue }
                        return .failed(.socketIOFailed(errno: errno, syscall: "writev"))
                    }
                    if written == 0 {
                        return .failed(.unexpectedEOF(bytesExpected: (firstCount - firstOffset) + (secondCount - secondOffset)))
                    }
                    let firstRemaining = firstCount - firstOffset
                    if written <= firstRemaining {
                        firstOffset += written
                    } else {
                        secondOffset += written - firstRemaining
                        firstOffset = firstCount
                    }
                }
                return .completed
            }
        }
        if case .failed(let error) = outcome { throw error }
    }

    private static func openSocket(host: String, port: Int) throws(ClickHouseError) -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var resolved: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &resolved)
        if lookup != 0 || resolved == nil {
            throw .connectionFailed(reason: "DNS resolution failed: \(String(cString: gai_strerror(lookup)))")
        }
        defer { freeaddrinfo(resolved) }
        guard let addressInformation = resolved else {
            throw .connectionFailed(reason: "DNS resolution returned no addrinfo")
        }
        let handle: Int32 = socket(addressInformation.pointee.ai_family, addressInformation.pointee.ai_socktype, addressInformation.pointee.ai_protocol)
        if handle < 0 {
            throw .connectionFailed(reason: "socket() failed: \(String(cString: strerror(errno)))")
        }
        var nodelay: Int32 = 1
        setsockopt(handle, Int32(IPPROTO_TCP), TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        var receiveBufferBytes: Int32 = 4 * 1024 * 1024
        setsockopt(handle, SOL_SOCKET, SO_RCVBUF, &receiveBufferBytes, socklen_t(MemoryLayout<Int32>.size))
        var sendBufferBytes: Int32 = 4 * 1024 * 1024
        setsockopt(handle, SOL_SOCKET, SO_SNDBUF, &sendBufferBytes, socklen_t(MemoryLayout<Int32>.size))
        let connectStatus = connect(handle, addressInformation.pointee.ai_addr, addressInformation.pointee.ai_addrlen)
        if connectStatus != 0 {
            let detail = String(cString: strerror(errno))
            #if canImport(Darwin)
            _ = Darwin.close(handle)
            #else
            _ = Glibc.close(handle)
            #endif
            throw .connectionFailed(reason: "connect() failed: \(detail)")
        }
        return handle
    }
}
