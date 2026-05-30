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

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Reconnection policy for the raw transport. The connection layer
// applies exponential backoff between reconnect attempts on transient
// I/O failures (EPIPE / ECONNRESET on send or recv, recv returning 0
// for an unexpected mid-stream EOF). Backoff doubles each attempt
// starting at initialBackoff and is clamped at maxBackoff.
//
// `maxAttempts == 0` disables reconnect: the first I/O failure surfaces
// as `RawClickHouseError.socketIOFailed` or `.unexpectedEOF` without
// any retry. Default of 5 attempts plus the 100ms→5s cap matches the
// budget called out in the resilience layer-back spec.
public struct ReconnectionPolicy: Sendable, Equatable {

    public let maxAttempts: Int
    public let initialBackoff: Duration
    public let maxBackoff: Duration

    public static let `default` = ReconnectionPolicy(
        maxAttempts: 5,
        initialBackoff: .milliseconds(100),
        maxBackoff: .seconds(5)
    )

    public static let disabled = ReconnectionPolicy(
        maxAttempts: 0,
        initialBackoff: .milliseconds(0),
        maxBackoff: .milliseconds(0)
    )

    public init(maxAttempts: Int, initialBackoff: Duration, maxBackoff: Duration) {
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
    }
}

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
public final class RawClickHouseConnection {

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
    private var arena: RawClickHouseArena
    public private(set) var serverInfo: ServerInfo
    public var negotiatedRevision: UInt64 { min(RawClickHouseQueryBuilder.revision, serverInfo.revision) }

    public init(
        host: String,
        port: Int,
        user: String = "default",
        password: String = "",
        database: String = "default",
        reconnectionPolicy: ReconnectionPolicy = .default
    ) throws(RawClickHouseError) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.reconnectionPolicy = reconnectionPolicy
        self.arena = RawClickHouseArena()
        self.serverInfo = ServerInfo(name: "", major: 0, minor: 0, revision: 0)
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

    public func sendQuery(_ sql: String) throws(RawClickHouseError) {
        let bytes = RawClickHouseQueryBuilder.buildQuery(sql)
        try sendAllWithReconnect(bytes)
    }

    // Pulls server packets until EndOfStream. Calls `consume` for each
    // Data packet (Totals/Extremes/Log/ProfileEvents pass through too;
    // empty header-only blocks are skipped). Returns the cumulative
    // row count across all data packets.
    public func receiveBlocks(_ consume: (RawClickHouseBlock, UnsafeRawBufferPointer) throws -> Void) throws(RawClickHouseError) -> Int {
        var totalRows = 0
        while true {
            let packetType = try readUVarInt()
            switch packetType {
            case 1: // Data
                totalRows += try readBlockPacket(revision: negotiatedRevision, consume: consume)
            case 2:
                let exception = try readExceptionPacket()
                throw .queryFailed(serverException: exception)
            case 3:
                try skipProgressPacket(revision: negotiatedRevision)
            case 5:
                return totalRows
            case 6:
                try skipProfileInfoPacket(revision: negotiatedRevision)
            case 7, 8: // Totals / Extremes
                totalRows += try readBlockPacket(revision: negotiatedRevision, consume: consume)
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
                throw .protocolError(stage: "receiveBlocks", message: "unexpected packet type \(packetType)")
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
    public func receiveBlocksDrain(_ consume: (Int, [String], [String]) throws -> Void) throws(RawClickHouseError) -> Int {
        var totalRows = 0
        while true {
            let packetType = try readUVarInt()
            switch packetType {
            case 1, 7, 8:
                totalRows += try drainBlockPacket(revision: negotiatedRevision, consume: consume)
            case 2:
                let exception = try readExceptionPacket()
                throw .queryFailed(serverException: exception)
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
                throw .protocolError(stage: "receiveBlocksDrain", message: "unexpected packet type \(packetType)")
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
    public func receiveBlocksExtractingStrings(_ consume: (Int, [String], [String], [[UInt8]]) throws -> Void) throws(RawClickHouseError) -> Int {
        var totalRows = 0
        while true {
            let packetType = try readUVarInt()
            switch packetType {
            case 1, 7, 8:
                totalRows += try extractStringsBlockPacket(revision: negotiatedRevision, consume: consume)
            case 2:
                let exception = try readExceptionPacket()
                throw .queryFailed(serverException: exception)
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
                throw .protocolError(stage: "receiveBlocksExtractingStrings", message: "unexpected packet type \(packetType)")
            }
        }
    }

    // Single-scalar variant: drains one block containing one row + one
    // column and returns the body bytes for that column. Used by the
    // bench scalar-count path (count() queries). Throws if the result
    // is not exactly one row + one fixed-width column.
    public func receiveScalarUInt64() throws(RawClickHouseError) -> UInt64 {
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

    // Opens a fresh socket, sends Hello, parses ServerHello, sends
    // Addendum. Used by init and by every reconnect attempt. The arena
    // is reset to empty before each handshake to drop any stale bytes
    // left over from a torn connection.
    private func openAndHandshake() throws(RawClickHouseError) {
        arena.head = 0
        arena.tail = 0
        let handle = try Self.openSocket(host: host, port: port)
        socketHandle = handle
        do {
            try sendAllOnce(RawClickHouseQueryBuilder.buildHello(database: database, user: user, password: password))
            self.serverInfo = try receiveHello()
            try sendAllOnce(RawClickHouseQueryBuilder.buildAddendum())
        } catch {
            close()
            throw error
        }
    }

    // Reconnect with bounded exponential backoff. Each attempt sleeps
    // for the current backoff, then tries to re-establish the socket
    // and complete the handshake. Returns normally on success; throws
    // `.reconnectExhausted` if every attempt fails.
    private func reconnect() throws(RawClickHouseError) {
        if reconnectionPolicy.maxAttempts <= 0 {
            throw .reconnectExhausted(attempts: 0)
        }
        close()
        var backoff = reconnectionPolicy.initialBackoff
        var lastError: RawClickHouseError = .reconnectExhausted(attempts: 0)
        for attempt in 1...reconnectionPolicy.maxAttempts {
            sleepFor(duration: backoff)
            do {
                try openAndHandshake()
                return
            } catch {
                lastError = error
                backoff = doubleBackoff(current: backoff, cap: reconnectionPolicy.maxBackoff)
                if attempt == reconnectionPolicy.maxAttempts { break }
            }
        }
        _ = lastError
        throw .reconnectExhausted(attempts: reconnectionPolicy.maxAttempts)
    }

    private func sleepFor(duration: Duration) {
        let nanos = duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
        if nanos <= 0 { return }
        var spec = timespec(tv_sec: Int(nanos / 1_000_000_000), tv_nsec: Int(nanos % 1_000_000_000))
        var remainder = timespec(tv_sec: 0, tv_nsec: 0)
        _ = nanosleep(&spec, &remainder)
    }

    private func doubleBackoff(current: Duration, cap: Duration) -> Duration {
        let currentNs = current.components.seconds * 1_000_000_000 + current.components.attoseconds / 1_000_000_000
        let doubled = currentNs &* 2
        let capNs = cap.components.seconds * 1_000_000_000 + cap.components.attoseconds / 1_000_000_000
        let clamped = doubled > capNs ? capNs : doubled
        return .nanoseconds(clamped)
    }

    private func receiveHello() throws(RawClickHouseError) -> ServerInfo {
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
        try skipServerHelloTail(clientRevision: RawClickHouseQueryBuilder.revision, serverRevision: revision)
        return ServerInfo(name: name, major: major, minor: minor, revision: revision)
    }

    private func skipServerHelloTail(clientRevision: UInt64, serverRevision: UInt64) throws(RawClickHouseError) {
        let effective = min(clientRevision, serverRevision)
        if effective >= 54_471 { _ = try readUVarInt() } // parallelReplicasProtocolVersion
        if effective >= 54_058 { _ = try readString() } // timezone
        if effective >= 54_372 { _ = try readString() } // display name
        if effective >= 54_401 { _ = try readUVarInt() } // version patch
        if effective >= 54_470 {
            _ = try readString() // chunked send
            _ = try readString() // chunked recv
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

    // Walks a Block (interleaved per-column header + body) without
    // exposing it to the caller. Used to drain Log and ProfileEvents
    // packets which carry text-typed columns the floor parser does not
    // expose to consumers.
    private func skipBlock(revision: UInt64) throws(RawClickHouseError) {
        let prologue = try parsePrologue()
        for _ in 0..<prologue.columnCount {
            let header = try parseColumnHeader(revision: revision)
            try skipColumnBody(typeName: header.type, rows: prologue.rowCount)
        }
        arena.compact()
    }

    private func parsePrologue() throws(RawClickHouseError) -> (columnCount: Int, rowCount: Int) {
        while true {
            let parseOutcome: ParsePrologueOutcome = arena.withReadPointer { base, available in
                do {
                    let result = try RawClickHouseBlockParser.parsePrologue(base: base, offset: 0, limit: available)
                    return .ready(columnCount: result.columnCount, rowCount: result.rowCount, consumed: result.consumed)
                } catch RawClickHouseParseError.needsMoreBytes {
                    return .needsMoreBytes
                } catch RawClickHouseParseError.malformed(let stage, let message) {
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

    private func parseColumnHeader(revision: UInt64) throws(RawClickHouseError) -> (name: String, type: String) {
        while true {
            let outcome: ParseColumnHeaderOutcome = arena.withReadPointer { base, available in
                do {
                    let result = try RawClickHouseBlockParser.parseColumnHeader(base: base, offset: 0, limit: available, revision: revision)
                    return .ready(name: result.name, type: result.type, consumed: result.consumed)
                } catch RawClickHouseParseError.needsMoreBytes {
                    return .needsMoreBytes
                } catch RawClickHouseParseError.malformed(let stage, let message) {
                    return .malformed(stage: stage, message: message)
                } catch {
                    return .malformed(stage: "column header", message: "\(error)")
                }
            }
            switch outcome {
            case .ready(let name, let type, let consumed):
                arena.advanceHead(by: consumed)
                return (name, type)
            case .needsMoreBytes:
                try fillMore(minBytes: 1)
            case .malformed(let stage, let message):
                throw .protocolError(stage: stage, message: message)
            }
        }
    }

    // Reads the per-column prefix CH emits for LowCardinality, Map, and
    // Array(Tuple(...)) substreams BEFORE the column body. For a flat
    // LowCardinality(T) this is one UInt64 (KeysSerializationVersion =
    // 1); for Array(T) it recurses into the inner T; for Map(K, V) it
    // recurses into both K and V. Skipped entirely when rowCount == 0.
    private func skipColumnPrefix(typeName: String, rows: Int) throws(RawClickHouseError) {
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
            let (keyType, valueType) = splitMapInner(inner)
            try skipColumnPrefix(typeName: keyType, rows: rows)
            try skipColumnPrefix(typeName: valueType, rows: rows)
            return
        }
        if typeName.hasPrefix("Nullable(") {
            let inner = innerType(typeName: typeName, prefix: "Nullable(")
            try skipColumnPrefix(typeName: inner, rows: rows)
            return
        }
    }

    private func skipColumnBody(typeName: String, rows: Int) throws(RawClickHouseError) {
        try skipColumnPrefix(typeName: typeName, rows: rows)
        try skipColumnBodyAfterPrefix(typeName: typeName, rows: rows)
    }

    private func skipColumnBodyAfterPrefix(typeName: String, rows: Int) throws(RawClickHouseError) {
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
        if typeName == "JSON" || typeName.hasPrefix("JSON(") || typeName.hasPrefix("Object(") {
            try skipJSONBody(rows: rows)
            return
        }
        let byteCount = try columnByteWidth(typeName: typeName, rows: rows)
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
    private func skipStringRows(rows: Int) throws(RawClickHouseError) {
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
                let maxLengthBytes = min(available, RawClickHouseWire.uvarintMaxBytes)
                while lengthBytes < maxLengthBytes {
                    let byte = (base + head + lengthBytes)[0]
                    if byte < 0x80 {
                        length |= UInt64(byte) << shift
                        lengthBytes += 1
                        break
                    }
                    length |= UInt64(byte & 0x7F) << shift
                    shift += 7
                    lengthBytes += 1
                    if lengthBytes == RawClickHouseWire.uvarintMaxBytes {
                        arena.head = head
                        throw .protocolError(stage: "uvarint", message: "overflow")
                    }
                }
                // If we did not terminate (top bit of last byte still set), refill.
                if lengthBytes == maxLengthBytes && maxLengthBytes < RawClickHouseWire.uvarintMaxBytes {
                    break inner
                }
                let lengthInt = Int(length)
                if (tail - head) < lengthBytes + lengthInt {
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
    private func skipLowCardinalityBody(typeName: String, rows: Int) throws(RawClickHouseError) {
        if rows == 0 { return }
        let inner = innerType(typeName: typeName, prefix: "LowCardinality(")
        let serializationType = try readFixedInt(UInt64.self)
        let keyWidth = lowCardinalityKeyWidth(serializationType: serializationType)
        let dictionarySize = try readFixedInt(UInt64.self)
        try skipColumnBodyAfterPrefix(typeName: inner, rows: Int(dictionarySize))
        let indicesCount = try readFixedInt(UInt64.self)
        try skipBytes(Int(indicesCount) * keyWidth)
    }

    private func lowCardinalityKeyWidth(serializationType: UInt64) -> Int {
        switch serializationType & 0xFF {
        case 0: return 1
        case 1: return 2
        case 2: return 4
        default: return 8
        }
    }

    // Array(T) body layout:
    //   UInt64[rows] offsets (cumulative end indices into inner element list)
    //   inner column with totalElements rows (= last offset, or 0 if rows == 0)
    private func skipArrayBody(typeName: String, rows: Int) throws(RawClickHouseError) {
        let inner = innerType(typeName: typeName, prefix: "Array(")
        var totalElements: UInt64 = 0
        for index in 0..<rows {
            let value = try readFixedInt(UInt64.self)
            if index == rows - 1 {
                totalElements = value
            }
        }
        try skipColumnBodyAfterPrefix(typeName: inner, rows: Int(totalElements))
    }

    // Nullable(T) body layout:
    //   UInt8[rows] null map
    //   inner column with rows values
    private func skipNullableBody(typeName: String, rows: Int) throws(RawClickHouseError) {
        let inner = innerType(typeName: typeName, prefix: "Nullable(")
        try skipBytes(rows)
        try skipColumnBodyAfterPrefix(typeName: inner, rows: rows)
    }

    // Map(K, V) body layout: same as Array(Tuple(K, V)):
    //   UInt64[rows] offsets
    //   K column with totalElements rows
    //   V column with totalElements rows
    private func skipMapBody(typeName: String, rows: Int) throws(RawClickHouseError) {
        let inner = innerType(typeName: typeName, prefix: "Map(")
        let (keyType, valueType) = splitMapInner(inner)
        var totalElements: UInt64 = 0
        for index in 0..<rows {
            let value = try readFixedInt(UInt64.self)
            if index == rows - 1 {
                totalElements = value
            }
        }
        try skipColumnBodyAfterPrefix(typeName: keyType, rows: Int(totalElements))
        try skipColumnBodyAfterPrefix(typeName: valueType, rows: Int(totalElements))
    }

    // JSON body (CH >= 24.10 dynamic JSON): a length-prefixed binary
    // payload per row. Each row begins with a UVarInt giving total
    // payload byte length, followed by that many bytes. This is the
    // minimum-viable skipper; full structural decode is not needed for
    // the bench, which never SELECTs JSON columns in the floor suite.
    private func skipJSONBody(rows: Int) throws(RawClickHouseError) {
        for _ in 0..<rows {
            let length = try readUVarInt()
            try skipBytes(Int(length))
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
    private func splitMapInner(_ inner: String) -> (String, String) {
        var depth = 0
        var splitOffset = -1
        let bytes = Array(inner.utf8)
        for (offset, byte) in bytes.enumerated() {
            switch byte {
            case 0x28: depth += 1
            case 0x29: depth -= 1
            case 0x2C where depth == 0:
                splitOffset = offset
            default:
                continue
            }
            if splitOffset >= 0 { break }
        }
        if splitOffset < 0 { return (inner, "") }
        let keyPart = String(decoding: bytes[0..<splitOffset], as: Unicode.UTF8.self)
        var valueStart = splitOffset + 1
        while valueStart < bytes.count, bytes[valueStart] == 0x20 { valueStart += 1 }
        let valuePart = String(decoding: bytes[valueStart..<bytes.count], as: Unicode.UTF8.self)
        return (keyPart, valuePart)
    }

    private func drainBlockPacket(revision: UInt64, consume: (Int, [String], [String]) throws -> Void) throws(RawClickHouseError) -> Int {
        _ = try readString()
        let prologue = try parsePrologue()
        var names: [String] = []
        var types: [String] = []
        names.reserveCapacity(prologue.columnCount)
        types.reserveCapacity(prologue.columnCount)
        for _ in 0..<prologue.columnCount {
            let header = try parseColumnHeader(revision: revision)
            names.append(header.name)
            types.append(header.type)
            try skipColumnBody(typeName: header.type, rows: prologue.rowCount)
        }
        if prologue.rowCount > 0 {
            do {
                try consume(prologue.rowCount, names, types)
            } catch let error as RawClickHouseError {
                throw error
            } catch {
                throw .protocolError(stage: "drainBlockPacket consume", message: "\(error)")
            }
        }
        arena.compact()
        return prologue.rowCount
    }

    private func extractStringsBlockPacket(revision: UInt64, consume: (Int, [String], [String], [[UInt8]]) throws -> Void) throws(RawClickHouseError) -> Int {
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
            names.append(header.name)
            types.append(header.type)
            var body: [UInt8] = []
            if header.type == "String" {
                try copyStringColumnBody(rows: prologue.rowCount, into: &body)
            } else if header.type.hasPrefix("FixedString(") {
                let width = fixedStringWidth(header.type)
                try copyFixedBytes(byteCount: width * prologue.rowCount, into: &body)
            } else {
                try skipColumnBody(typeName: header.type, rows: prologue.rowCount)
            }
            bodies.append(body)
        }
        if prologue.rowCount > 0 {
            do {
                try consume(prologue.rowCount, names, types, bodies)
            } catch let error as RawClickHouseError {
                throw error
            } catch {
                throw .protocolError(stage: "extractStringsBlockPacket consume", message: "\(error)")
            }
        }
        arena.compact()
        return prologue.rowCount
    }

    private func fixedStringWidth(_ typeName: String) -> Int {
        let widthStart = typeName.index(typeName.startIndex, offsetBy: "FixedString(".count)
        let widthEnd = typeName.firstIndex(of: ")") ?? typeName.endIndex
        return Int(typeName[widthStart..<widthEnd]) ?? 0
    }

    private func copyStringColumnBody(rows: Int, into output: inout [UInt8]) throws(RawClickHouseError) {
        for _ in 0..<rows {
            let length = try readUVarInt()
            let count = Int(length)
            try ensureBytes(count)
            arena.withReadPointer { base, _ in
                let buffer = UnsafeBufferPointer(start: base, count: count)
                RawClickHouseWire.writeUVarInt(length, into: &output)
                output.append(contentsOf: buffer)
            }
            arena.advanceHead(by: count)
        }
    }

    private func copyFixedBytes(byteCount: Int, into output: inout [UInt8]) throws(RawClickHouseError) {
        if byteCount <= 0 { return }
        try ensureBytes(byteCount)
        arena.withReadPointer { base, _ in
            let buffer = UnsafeBufferPointer(start: base, count: byteCount)
            output.append(contentsOf: buffer)
        }
        arena.advanceHead(by: byteCount)
    }

    private func skipBytes(_ count: Int) throws(RawClickHouseError) {
        if count <= 0 { return }
        try ensureBytes(count)
        arena.advanceHead(by: count)
    }

    private func readBlockPacket(revision: UInt64, consume: (RawClickHouseBlock, UnsafeRawBufferPointer) throws -> Void) throws(RawClickHouseError) -> Int {
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
            names.append(header.name)
            types.append(header.type)
            let start = combined.count
            try copyColumnBody(typeName: header.type, rows: prologue.rowCount, into: &combined)
            combinedRanges.append(start..<combined.count)
        }
        let block = RawClickHouseBlock(
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
            } catch let error as RawClickHouseError {
                throw error
            } catch {
                throw .protocolError(stage: "readBlockPacket consume", message: "\(error)")
            }
        }
        arena.compact()
        return prologue.rowCount
    }

    private func copyColumnBody(typeName: String, rows: Int, into output: inout [UInt8]) throws(RawClickHouseError) {
        let byteCount = try columnByteWidth(typeName: typeName, rows: rows)
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
        for _ in 0..<rows {
            let length = try readUVarInt()
            let count = Int(length)
            try ensureBytes(count)
            arena.withReadPointer { base, _ in
                let buffer = UnsafeBufferPointer(start: base, count: count)
                RawClickHouseWire.writeUVarInt(length, into: &output)
                output.append(contentsOf: buffer)
            }
            arena.advanceHead(by: count)
        }
    }

    private func columnByteWidth(typeName: String, rows: Int) throws(RawClickHouseError) -> Int {
        switch typeName {
        case "UInt8", "Int8", "Bool": return rows
        case "UInt16", "Int16", "Date": return rows * 2
        case "UInt32", "Int32", "Float32", "DateTime", "IPv4": return rows * 4
        case "UInt64", "Int64", "Float64": return rows * 8
        case "UInt128", "Int128", "UUID", "IPv6": return rows * 16
        case "UInt256", "Int256": return rows * 32
        case "String": return -1
        default:
            if typeName.hasPrefix("Enum8(") { return rows }
            if typeName.hasPrefix("Enum16(") { return rows * 2 }
            if typeName.hasPrefix("DateTime(") { return rows * 4 }
            if typeName.hasPrefix("DateTime64(") { return rows * 8 }
            if typeName.hasPrefix("FixedString(") {
                let widthStart = typeName.index(typeName.startIndex, offsetBy: "FixedString(".count)
                let widthEnd = typeName.firstIndex(of: ")") ?? typeName.endIndex
                let width = Int(typeName[widthStart..<widthEnd]) ?? 0
                return rows * width
            }
            throw .protocolError(stage: "columnByteWidth", message: "unsupported column type \(typeName)")
        }
    }

    private func readExceptionPacket() throws(RawClickHouseError) -> String {
        let code = try readFixedInt(Int32.self)
        let name = try readString()
        let message = try readString()
        _ = try readString() // stack trace
        let hasNested = try readByte()
        if hasNested != 0 {
            _ = try readExceptionPacket()
        }
        return "code=\(code) name=\(name) message=\(message)"
    }

    private func skipProgressPacket(revision: UInt64) throws(RawClickHouseError) {
        _ = try readUVarInt() // rows
        _ = try readUVarInt() // bytes
        _ = try readUVarInt() // total rows
        if revision >= 54_463 { _ = try readUVarInt() } // total bytes
        if revision >= 54_420 {
            _ = try readUVarInt() // written rows
            _ = try readUVarInt() // written bytes
        }
        if revision >= 54_460 { _ = try readUVarInt() } // elapsed ns
    }

    private func skipProfileInfoPacket(revision: UInt64) throws(RawClickHouseError) {
        _ = try readUVarInt() // rows
        _ = try readUVarInt() // blocks
        _ = try readUVarInt() // bytes
        _ = try readByte() // applied limit
        _ = try readUVarInt() // rows before limit
        _ = try readByte() // calculated rows before limit
        if revision >= 54_469 {
            _ = try readByte() // applied aggregation
            _ = try readUVarInt() // rows before aggregation
        }
    }

    @inline(__always)
    private func readByte() throws(RawClickHouseError) -> UInt8 {
        try ensureBytes(1)
        let storage = arena.owner
        let value = (storage.base + arena.head)[0]
        arena.head += 1
        return value
    }

    @inline(__always)
    private func readFixedInt<T: FixedWidthInteger>(_ type: T.Type) throws(RawClickHouseError) -> T {
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
    private func readUVarInt() throws(RawClickHouseError) -> UInt64 {
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
                let cap = min(available, RawClickHouseWire.uvarintMaxBytes)
                while index < cap {
                    let byte = base[index]
                    if byte < 0x80 {
                        value |= UInt64(byte) << shift
                        arena.head += index + 1
                        return value
                    }
                    value |= UInt64(byte & 0x7F) << shift
                    shift += 7
                    index += 1
                }
                if index == RawClickHouseWire.uvarintMaxBytes {
                    throw .protocolError(stage: "uvarint", message: "overflow")
                }
            }
            try fillMore(minBytes: 1)
        }
    }

    private func readString() throws(RawClickHouseError) -> String {
        while true {
            let outcome: ParseStringOutcome = arena.withReadPointer { base, available in
                do {
                    let parsed = try RawClickHouseWire.readString(base: base, offset: 0, limit: available)
                    return .ready(value: parsed.0, consumed: parsed.1)
                } catch RawClickHouseParseError.needsMoreBytes {
                    return .needsMoreBytes
                } catch RawClickHouseParseError.malformed(let stage, let message) {
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

    private func ensureBytes(_ count: Int) throws(RawClickHouseError) {
        while arena.readable < count {
            try fillMore(minBytes: count - arena.readable)
        }
    }

    // recv() loop helper. Detects:
    //  * -1 with EPIPE / ECONNRESET / ENOTCONN / ECONNABORTED → socket
    //    is gone; reconnect (best-effort) so the *next* sendQuery
    //    works, and surface `.socketIOFailed` to the caller — the
    //    in-flight receive cannot be resumed because the server has
    //    already started streaming a result.
    //  * -1 with any other errno → surface `.socketIOFailed` as a
    //    hard error. The connection is reconnected so the next
    //    sendQuery has a chance to succeed.
    //  * 0 → unexpected EOF mid-stream; reconnect and throw
    //    `.unexpectedEOF`.
    private func fillMore(minBytes: Int) throws(RawClickHouseError) {
        arena.ensureFreeCapacity(max(minBytes, 4096))
        let storage = arena.owner
        #if canImport(Darwin)
        let received = Darwin.recv(socketHandle, storage.base + arena.tail, storage.capacity - arena.tail, 0)
        #else
        let received = Glibc.recv(socketHandle, storage.base + arena.tail, storage.capacity - arena.tail, 0)
        #endif
        if received < 0 {
            let capturedErrno = errno
            try? reconnect()
            throw .socketIOFailed(errno: capturedErrno, syscall: "recv")
        }
        if received == 0 {
            try? reconnect()
            throw .unexpectedEOF(bytesExpected: minBytes)
        }
        arena.tail += received
    }

    // Send-with-reconnect entry point used by `sendQuery`. A query has
    // not yet had any server-side response begin streaming, so a
    // transient EPIPE / ECONNRESET on the send is safe to retry after a
    // reconnect. We attempt up to `reconnectionPolicy.maxAttempts` send
    // retries, each preceded by a fresh reconnect + handshake.
    private func sendAllWithReconnect(_ bytes: [UInt8]) throws(RawClickHouseError) {
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

    private func shouldReconnect(after error: RawClickHouseError) -> Bool {
        switch error {
        case .socketIOFailed, .unexpectedEOF:
            return reconnectionPolicy.maxAttempts > 0
        case .connectionFailed, .protocolError, .queryFailed, .reconnectExhausted:
            return false
        }
    }

    private func sendAllOnce(_ bytes: [UInt8]) throws(RawClickHouseError) {
        var offset = 0
        let handle = socketHandle
        let totalCount = bytes.count
        let outcome: RawClickHouseError? = bytes.withUnsafeBufferPointer { buffer -> RawClickHouseError? in
            guard let base = buffer.baseAddress else { return nil }
            while offset < totalCount {
                #if canImport(Darwin)
                let written = Darwin.send(handle, base + offset, totalCount - offset, 0)
                #else
                let written = Glibc.send(handle, base + offset, totalCount - offset, Int32(MSG_NOSIGNAL))
                #endif
                if written < 0 {
                    return .socketIOFailed(errno: errno, syscall: "send")
                }
                if written == 0 {
                    return .unexpectedEOF(bytesExpected: totalCount - offset)
                }
                offset += written
            }
            return nil
        }
        if let error = outcome { throw error }
    }

    private static func openSocket(host: String, port: Int) throws(RawClickHouseError) -> Int32 {
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
        guard let info = resolved else {
            throw .connectionFailed(reason: "DNS resolution returned no addrinfo")
        }
        let handle: Int32 = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if handle < 0 {
            throw .connectionFailed(reason: "socket() failed: \(String(cString: strerror(errno)))")
        }
        var nodelay: Int32 = 1
        setsockopt(handle, Int32(IPPROTO_TCP), TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        var receiveBufferBytes: Int32 = 4 * 1024 * 1024
        setsockopt(handle, SOL_SOCKET, SO_RCVBUF, &receiveBufferBytes, socklen_t(MemoryLayout<Int32>.size))
        var sendBufferBytes: Int32 = 4 * 1024 * 1024
        setsockopt(handle, SOL_SOCKET, SO_SNDBUF, &sendBufferBytes, socklen_t(MemoryLayout<Int32>.size))
        let connectStatus = connect(handle, info.pointee.ai_addr, info.pointee.ai_addrlen)
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
