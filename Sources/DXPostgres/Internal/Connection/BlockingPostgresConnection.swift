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
#elseif canImport(Darwin)
import Darwin
#endif
import DXCore
import NIOCore

// One PostgreSQL connection driven by synchronous, blocking socket I/O on a
// single owning thread, reusing the same wire codecs as the event-loop path
// (FrontendMessage, BackendMessageDecoder, ResultAccumulator, ScramClient). A
// connection is strictly sequential, so blocking the owning thread on recv costs
// nothing the protocol does not already require; the async facade above keeps the
// caller non-blocking by handing work to this thread and awaiting the result.
//
// `@unchecked Sendable` is sound because every method runs on the single thread
// that owns the file descriptor; the pool never touches one connection from two
// threads at once.
final class BlockingPostgresConnection: @unchecked Sendable {

    private static let initialReadBufferBytes = 16 * 1024
    private static let initialWriteScratchBytes = 512
    private static let receiveChunkBytes = 64 * 1024

    private let descriptor: Int32
    private let allocator = ByteBufferAllocator()
    private var readBuffer: ByteBuffer
    private var writeScratch: ByteBuffer
    private var preparedStatements: [String: String] = [:]
    private var statementCounter: UInt64 = 0
    private var lastInlineSQL: String = ""
    private var lastInlineName: String = ""

    init(descriptor: Int32) {
        self.descriptor = descriptor
        self.readBuffer = allocator.buffer(capacity: Self.initialReadBufferBytes)
        self.writeScratch = allocator.buffer(capacity: Self.initialWriteScratchBytes)
    }

    static func connect(host: String, port: Int, username: String, password: String, database: String, applicationName: String) throws(PostgresError) -> BlockingPostgresConnection {
        let descriptor = try openSocket(host: host, port: port)
        let connection = BlockingPostgresConnection(descriptor: descriptor)
        do {
            try connection.performStartup(username: username, password: password, database: database, applicationName: applicationName)
        } catch {
            connection.close()
            throw error
        }
        return connection
    }

    func close() {
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
        _ = Glibc.close(descriptor)
    }

    // Sends one fully-built wire buffer straight from its storage (no [UInt8] copy).
    func writeAll(_ buffer: ByteBuffer) throws(PostgresError) {
        var failed = false
        buffer.withUnsafeReadableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = send(descriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset, Int32(MSG_NOSIGNAL))
                if written <= 0 { failed = true; return }
                offset += written
            }
        }
        if failed { throw PostgresError.transportError(reason: "blocking send failed") }
    }

    // Returns the next decoded backend message, refilling from the socket only
    // when the accumulation buffer does not already hold a complete frame.
    func nextMessage() throws(PostgresError) -> BackendMessage {
        while true {
            switch try BackendMessageDecoder.decodeOne(from: readBuffer) {
            case .message(let message, let consumed):
                readBuffer.moveReaderIndex(forwardBy: consumed)
                reclaimReadBuffer()
                return message
            case .needMore:
                try fillReadBuffer()
            }
        }
    }

    // Submits any statement over the simple-query protocol and returns the rows
    // exactly as the server framed them: each field is its raw wire bytes
    // (`PostgresCell.bytes`) or `PostgresCell.sqlNull`. Simple-query results are in
    // text format, so the bytes are the value's text rendering; the caller decodes.
    // Streaming primitive: sends the statement, then hands each row to onRow as a
    // borrowed view read in place from the read buffer. No per-row allocation; the
    // caller reads only the fields it needs and copies what it keeps. Returns the
    // column descriptions. The owned execute below is this stream collected into a
    // PostgresResult.
    func execute(_ sql: String, onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        writeScratch.clear()
        FrontendMessage.appendQuery(into: &writeScratch, sql: sql)
        try writeAll(writeScratch)
        return try streamResult(onRow: onRow)
    }

    // Parameterized read over the extended protocol: the bound values are sent as
    // text parameters for $1, $2, …, never spliced into the SQL, and results come
    // back in text format streamed through the borrowed row view. The statement is
    // parsed once and cached.
    func query(_ sql: String, bindings: [PostgresCell], onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        let plan = planStatement(for: sql)
        do {
            writeScratch.clear()
            let name = appendParseIfNeeded(plan, sql: sql, into: &writeScratch)
            FrontendMessage.appendBindTextResult(into: &writeScratch, statementName: name, parameters: bindings)
            if case .parse = plan {
                FrontendMessage.appendDescribePortal(into: &writeScratch, name: "")
            }
            FrontendMessage.appendExecute(into: &writeScratch, portalName: "", maxRows: 0)
            FrontendMessage.appendSync(into: &writeScratch)
            try writeAll(writeScratch)
            return try streamResult(onRow: onRow)
        } catch {
            preparedStatements.removeValue(forKey: sql)
            throw error
        }
    }

    private func streamResult(onRow: (PostgresRowView) throws(PostgresError) -> Void) throws(PostgresError) -> [PostgresColumn] {
        var columns: [PostgresColumn] = []
        while true {
            while readBuffer.readableBytes < 5 { try fillReadBuffer() }
            let base = readBuffer.readerIndex
            let length = Int(readBuffer.getInteger(at: base + 1, as: Int32.self) ?? 0)
            let total = length + 1
            while readBuffer.readableBytes < total { try fillReadBuffer() }
            if (readBuffer.getInteger(at: base, as: UInt8.self) ?? 0) == 0x44 {
                try onRow(PostgresRowView(buffer: readBuffer, base: base))
                readBuffer.moveReaderIndex(forwardBy: total)
                reclaimReadBuffer()
            } else if try absorbControlMessage(into: &columns) {
                return columns
            }
        }
    }

    private func absorbControlMessage(into columns: inout [PostgresColumn]) throws(PostgresError) -> Bool {
        switch try nextMessage() {
        case .rowDescription(let fields):
            columns = fields.map { PostgresColumn(name: $0.name, dataTypeObjectID: $0.dataTypeObjectID, format: $0.format) }
            return false
        case .readyForQuery:
            return true
        case .error(let serverError):
            try consumeUntilReadyForQuery()
            throw PostgresError.server(serverError)
        default:
            return false
        }
    }

    func execute(_ sql: String) throws(PostgresError) -> PostgresResult {
        var rows: [[PostgresCell]] = []
        let columns = try execute(sql) { (view: PostgresRowView) throws(PostgresError) in
            var cells: [PostgresCell] = []
            cells.reserveCapacity(view.fieldCount)
            var index = 0
            while index < view.fieldCount {
                cells.append(view.isNull(index) ? .sqlNull : .bytes(try view.bytes(index)))
                index += 1
            }
            rows.append(cells)
        }
        return PostgresResult(columns: columns, rows: rows)
    }

    func query(_ sql: String, bindings: [PostgresCell]) throws(PostgresError) -> PostgresResult {
        var rows: [[PostgresCell]] = []
        let columns = try query(sql, bindings: bindings) { (view: PostgresRowView) throws(PostgresError) in
            var cells: [PostgresCell] = []
            cells.reserveCapacity(view.fieldCount)
            var index = 0
            while index < view.fieldCount {
                cells.append(view.isNull(index) ? .sqlNull : .bytes(try view.bytes(index)))
                index += 1
            }
            rows.append(cells)
        }
        return PostgresResult(columns: columns, rows: rows)
    }

    func listen(_ channel: String) throws(PostgresError) {
        writeScratch.clear()
        FrontendMessage.appendQuery(into: &writeScratch, sql: "LISTEN \"\(channel)\"")
        try writeAll(writeScratch)
        while true {
            switch try nextMessage() {
            case .readyForQuery:
                return
            case .error(let serverError):
                try consumeUntilReadyForQuery()
                throw PostgresError.server(serverError)
            default:
                continue
            }
        }
    }

    func awaitNotification() throws(PostgresError) -> PostgresNotification {
        while true {
            if case .notification(let processID, let channel, let payload) = try nextMessage() {
                return PostgresNotification(processID: processID, channel: channel, payload: payload)
            }
        }
    }

    private func consumeUntilReadyForQuery() throws(PostgresError) {
        while true {
            if case .readyForQuery = try nextMessage() { return }
        }
    }

    private func fillReadBuffer() throws(PostgresError) {
        var received = 0
        readBuffer.writeWithUnsafeMutableBytes(minimumWritableBytes: Self.receiveChunkBytes) { raw in
            received = recv(descriptor, raw.baseAddress, raw.count, 0)
            return received > 0 ? received : 0
        }
        guard received > 0 else { throw PostgresError.connectionClosed }
    }

    private func reclaimReadBuffer() {
        guard readBuffer.readerIndex > 16 * 1024, readBuffer.readableBytes == 0 else { return }
        readBuffer.clear()
    }

    // Zero-object fast path: the bound int64 is encoded straight into the Bind (no
    // [PostgresCell]/String/[UInt8]); decode is the same zero-object read. Fully zero-object.
    func queryScalarInt64Inline(_ sql: String, value param: Int64) throws(PostgresError) -> Int64 {
        if sql == lastInlineSQL {
            do {
                try sendPreparedScalarBind(statementName: lastInlineName, value: param)
                return try readScalarInt64()
            } catch {
                invalidateInlineCache(for: sql)
                throw error
            }
        }
        return try queryScalarInt64InlineColdPath(sql, value: param)
    }

    private func queryScalarInt64InlineColdPath(_ sql: String, value param: Int64) throws(PostgresError) -> Int64 {
        let plan = planStatement(for: sql)
        do {
            writeScratch.clear()
            let name = appendParseIfNeeded(plan, sql: sql, into: &writeScratch)
            FrontendMessage.appendBindInt64(into: &writeScratch, statementName: name, value: param)
            FrontendMessage.appendExecute(into: &writeScratch, portalName: "", maxRows: 0)
            FrontendMessage.appendSync(into: &writeScratch)
            try writeAll(writeScratch)
            let value = try readScalarInt64()
            lastInlineSQL = sql
            lastInlineName = name
            return value
        } catch {
            invalidateInlineCache(for: sql)
            throw error
        }
    }

    private func invalidateInlineCache(for sql: String) {
        preparedStatements.removeValue(forKey: sql)
        lastInlineSQL = ""
    }

    // Steady-state hot path for a statement already prepared by the cold path: the
    // Bind/Execute/Sync triple is written with direct big-endian stores into a stack
    // buffer and sent in one syscall, with no ByteBuffer allocation, copy-on-write
    // check, or bounds-managed append. The bound integer is rendered as decimal-ASCII
    // digits inline, so the whole exchange performs zero heap allocation.
    private func sendPreparedScalarBind(statementName: String, value: Int64) throws(PostgresError) {
        let negative = value < 0
        let magnitude = negative ? (~UInt64(bitPattern: value) &+ 1) : UInt64(bitPattern: value)
        var digitCount = 1
        var scan = magnitude
        while scan >= 10 { scan /= 10; digitCount += 1 }
        let paramLength = digitCount + (negative ? 1 : 0)
        let failed = sendScalarFrame(statementName: statementName, negative: negative, magnitude: magnitude, digitCount: digitCount, paramLength: paramLength)
        if failed { throw PostgresError.transportError(reason: "blocking send failed") }
    }

    private func sendScalarFrame(statementName: String, negative: Bool, magnitude: UInt64, digitCount: Int, paramLength: Int) -> Bool {
        let nameLength = statementName.utf8.count
        let bindLength = 4 + 1 + (nameLength + 1) + 2 + 2 + 2 + 4 + paramLength + 2 + 2
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bindLength + 1 + 9 + 5) { frame in
            var cursor = ScalarFrameCursor(frame)
            cursor.putByte(0x42)
            cursor.putInt32(Int32(bindLength))
            cursor.putByte(0)
            for byte in statementName.utf8 { cursor.putByte(byte) }
            cursor.putByte(0)
            cursor.putInt16(1)
            cursor.putInt16(0)
            cursor.putInt16(1)
            cursor.putInt32(Int32(paramLength))
            if negative { cursor.putByte(0x2D) }
            var divisor: UInt64 = 1
            for _ in 1..<digitCount { divisor *= 10 }
            var remainder = magnitude
            while divisor > 0 {
                cursor.putByte(0x30 &+ UInt8(remainder / divisor))
                remainder %= divisor
                divisor /= 10
            }
            cursor.putInt16(1)
            cursor.putInt16(1)
            cursor.putByte(0x45)
            cursor.putInt32(9)
            cursor.putByte(0)
            cursor.putInt32(0)
            cursor.putByte(0x53)
            cursor.putInt32(4)
            return sendRawFrame(frame, count: cursor.count)
        }
    }

    private func sendRawFrame(_ frame: UnsafeMutableBufferPointer<UInt8>, count: Int) -> Bool {
        guard let base = frame.baseAddress else { return true }
        var offset = 0
        while offset < count {
            let written = send(descriptor, base.advanced(by: offset), count - offset, Int32(MSG_NOSIGNAL))
            if written <= 0 { return true }
            offset += written
        }
        return false
    }

    // Pipelined zero-object scalar: every bound value is written as its own
    // Bind/Execute back-to-back, followed by a single trailing Sync, so the whole
    // chunk is in flight on the connection at once. Responses arrive in submission
    // order; each DataRow's int8 field is read in place into the output array. This
    // amortizes one network round-trip across the whole chunk, matching libpq
    // pipeline mode, while keeping the per-query allocation count at zero.
    func queryScalarInt64Pipelined(_ sql: String, values: [Int64]) throws(PostgresError) -> [Int64] {
        do {
            writeScratch.clear()
            let name = pipelineStatementName(for: sql, into: &writeScratch)
            for value in values {
                FrontendMessage.appendBindInt64(into: &writeScratch, statementName: name, value: value)
                FrontendMessage.appendExecute(into: &writeScratch, portalName: "", maxRows: 0)
            }
            FrontendMessage.appendSync(into: &writeScratch)
            try writeAll(writeScratch)
            return try readScalarInt64Batch(count: values.count)
        } catch {
            invalidateInlineCache(for: sql)
            throw error
        }
    }

    private func pipelineStatementName(for sql: String, into buffer: inout ByteBuffer) -> String {
        if sql == lastInlineSQL { return lastInlineName }
        let plan = planStatement(for: sql)
        let name = appendParseIfNeeded(plan, sql: sql, into: &buffer)
        lastInlineSQL = sql
        lastInlineName = name
        return name
    }

    private func readScalarInt64Batch(count: Int) throws(PostgresError) -> [Int64] {
        var values: [Int64] = []
        values.reserveCapacity(count)
        var sawReadyForQuery = false
        while !sawReadyForQuery {
            while readBuffer.readableBytes < 5 { try fillReadBuffer() }
            let base = readBuffer.readerIndex
            let tag = readBuffer.getInteger(at: base, as: UInt8.self) ?? 0
            let length = Int(readBuffer.getInteger(at: base + 1, as: Int32.self) ?? 0)
            let total = length + 1
            while readBuffer.readableBytes < total { try fillReadBuffer() }
            if tag == 0x45 { try throwScalarServerError() }
            if tag == 0x44 {
                let fieldCount = readBuffer.getInteger(at: base + 5, as: Int16.self) ?? 0
                if fieldCount > 0, Int(readBuffer.getInteger(at: base + 7, as: Int32.self) ?? -1) == 8 {
                    values.append(readBuffer.getInteger(at: base + 11, as: Int64.self) ?? 0)
                }
            } else if tag == 0x5A {
                sawReadyForQuery = true
            }
            readBuffer.moveReaderIndex(forwardBy: total)
            reclaimReadBuffer()
        }
        return values
    }

    private func throwScalarServerError() throws(PostgresError) -> Never {
        let message = try nextMessage()
        try consumeUntilReadyForQuery()
        guard case .error(let serverError) = message else {
            throw PostgresError.protocolError(reason: "expected an error response on the typed fast path")
        }
        throw PostgresError.server(serverError)
    }

    private func readScalarInt64() throws(PostgresError) -> Int64 {
        var value: Int64 = 0
        while true {
            while readBuffer.readableBytes < 5 { try fillReadBuffer() }
            let base = readBuffer.readerIndex
            let tag = readBuffer.getInteger(at: base, as: UInt8.self) ?? 0
            let length = Int(readBuffer.getInteger(at: base + 1, as: Int32.self) ?? 0)
            let total = length + 1
            while readBuffer.readableBytes < total { try fillReadBuffer() }
            if tag == 0x45 { try throwScalarServerError() }
            if tag == 0x44 {
                let fieldCount = readBuffer.getInteger(at: base + 5, as: Int16.self) ?? 0
                if fieldCount > 0 {
                    let fieldLength = Int(readBuffer.getInteger(at: base + 7, as: Int32.self) ?? -1)
                    if fieldLength == 8 {
                        value = readBuffer.getInteger(at: base + 11, as: Int64.self) ?? 0
                    }
                }
            }
            readBuffer.moveReaderIndex(forwardBy: total)
            reclaimReadBuffer()
            if tag == 0x5A { break }
        }
        return value
    }

    private enum Plan {

        case prepared(name: String)
        case parse(name: String)
    }

    private struct ScalarFrameCursor {

        private let buffer: UnsafeMutableBufferPointer<UInt8>
        private(set) var count: Int = 0

        init(_ buffer: UnsafeMutableBufferPointer<UInt8>) { self.buffer = buffer }

        mutating func putByte(_ value: UInt8) {
            buffer[count] = value
            count += 1
        }

        mutating func putInt16(_ value: Int16) {
            let bits = UInt16(bitPattern: value)
            buffer[count] = UInt8(bits >> 8)
            buffer[count + 1] = UInt8(bits & 0xFF)
            count += 2
        }

        mutating func putInt32(_ value: Int32) {
            let bits = UInt32(bitPattern: value)
            buffer[count] = UInt8(bits >> 24)
            buffer[count + 1] = UInt8((bits >> 16) & 0xFF)
            buffer[count + 2] = UInt8((bits >> 8) & 0xFF)
            buffer[count + 3] = UInt8(bits & 0xFF)
            count += 4
        }
    }

    private func planStatement(for sql: String) -> Plan {
        if let name = preparedStatements[sql] { return .prepared(name: name) }
        statementCounter += 1
        let name = "dxb\(statementCounter)"
        preparedStatements[sql] = name
        return .parse(name: name)
    }

    private func appendParseIfNeeded(_ plan: Plan, sql: String, into buffer: inout ByteBuffer) -> String {
        switch plan {
        case .prepared(let name): return name
        case .parse(let name):
            FrontendMessage.appendParse(into: &buffer, statementName: name, sql: sql)
            return name
        }
    }
}

extension BlockingPostgresConnection {

    fileprivate static func openSocket(host: String, port: Int) throws(PostgresError) -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var resolved: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resolved)
        guard status == 0, let list = resolved else { throw PostgresError.connectFailed(reason: "could not resolve \(host):\(port)") }
        defer { freeaddrinfo(list) }
        guard case .found(let descriptor) = dialFirst(list) else {
            throw PostgresError.connectFailed(reason: "could not connect to \(host):\(port)")
        }
        setNoDelay(descriptor)
        return descriptor
    }

    private static func dialFirst(_ list: UnsafeMutablePointer<addrinfo>) -> Lookup<Int32> {
        var node: UnsafeMutablePointer<addrinfo>? = list
        while let candidate = node {
            if case .found(let descriptor) = tryDial(candidate) { return .found(descriptor) }
            node = candidate.pointee.ai_next
        }
        return .notFound
    }

    private static func tryDial(_ candidate: UnsafeMutablePointer<addrinfo>) -> Lookup<Int32> {
        let descriptor = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
        guard descriptor >= 0 else { return .notFound }
        guard Glibc.connect(descriptor, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 else {
            _ = Glibc.close(descriptor)
            return .notFound
        }
        return .found(descriptor)
    }

    private static func setNoDelay(_ descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    fileprivate func performStartup(username: String, password: String, database: String, applicationName: String) throws(PostgresError) {
        try writeAll(FrontendMessage.startup(user: username, database: database, applicationName: applicationName, allocator: allocator))
        try authenticate(username: username, password: password)
        try awaitReadyForQuery()
    }

    private func authenticate(username: String, password: String) throws(PostgresError) {
        var complete = false
        while !complete {
            complete = try authenticationStep(username: username, password: password)
        }
    }

    private func authenticationStep(username: String, password: String) throws(PostgresError) -> Bool {
        let message = try nextMessage()
        guard case .authentication(let request) = message else { throw startupFailure(message) }
        return try answer(request, username: username, password: password)
    }

    private func answer(_ request: AuthenticationRequest, username: String, password: String) throws(PostgresError) -> Bool {
        switch request {
        case .ok: return true
        case .cleartextPassword: try writeAll(FrontendMessage.password(Array(password.utf8), allocator: allocator)); return false
        case .md5Password(let salt): try writeAll(FrontendMessage.password(Md5Authentication.token(username: username, password: password, salt: salt), allocator: allocator)); return false
        case .saslMechanisms(let mechanisms): try runScram(username: username, password: password, mechanisms: mechanisms); return false
        case .saslContinue, .saslFinal: throw PostgresError.protocolError(reason: "SASL continuation arrived before the SCRAM exchange started")
        case .unsupported(let code): throw PostgresError.unsupportedAuthentication(method: "authentication code \(code)")
        }
    }

    private func runScram(username: String, password: String, mechanisms: [String]) throws(PostgresError) {
        guard mechanisms.contains("SCRAM-SHA-256") else { throw PostgresError.unsupportedAuthentication(method: mechanisms.joined(separator: ", ")) }
        var client = ScramClient(username: "", password: password, clientNonce: ScramNonce.generate())
        try writeAll(FrontendMessage.saslInitialResponse(mechanism: "SCRAM-SHA-256", initialResponse: client.clientFirstMessage(), allocator: allocator))
        let serverFirst = try expectSASL(continuation: true)
        try writeAll(FrontendMessage.saslResponse(try client.clientFinalMessage(serverFirst: serverFirst), allocator: allocator))
        let serverFinal = try expectSASL(continuation: false)
        try client.verifyServerFinal(serverFinal)
    }

    private func expectSASL(continuation: Bool) throws(PostgresError) -> [UInt8] {
        let message = try nextMessage()
        switch message {
        case .authentication(.saslContinue(let data)) where continuation: return data
        case .authentication(.saslFinal(let data)) where !continuation: return data
        default: throw startupFailure(message)
        }
    }

    private func awaitReadyForQuery() throws(PostgresError) {
        while true {
            let message = try nextMessage()
            switch message {
            case .readyForQuery: return
            case .parameterStatus, .backendKeyData, .notice: continue
            case .error(let error): throw PostgresError.server(error)
            default: throw PostgresError.protocolError(reason: "unexpected message during the startup handshake")
            }
        }
    }

    private func startupFailure(_ message: BackendMessage) -> PostgresError {
        if case .error(let error) = message { return .server(error) }
        return .protocolError(reason: "expected an authentication message during the startup handshake")
    }
}
