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

    private let descriptor: Int32
    private let allocator = ByteBufferAllocator()
    private var readBuffer: ByteBuffer
    private var writeScratch: ByteBuffer
    private var scratch: [UInt8]
    private var preparedStatements: [String: String] = [:]
    private var statementCounter: UInt64 = 0

    private init(descriptor: Int32) {
        self.descriptor = descriptor
        self.readBuffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
        self.writeScratch = ByteBufferAllocator().buffer(capacity: 512)
        self.scratch = [UInt8](repeating: 0, count: 64 * 1024)
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

    // Sends one fully-built wire buffer, looping until every byte is written.
    func writeAll(_ buffer: ByteBuffer) throws(PostgresError) {
        var view = buffer
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        try sendAll(bytes)
    }

    private func sendAll(_ bytes: [UInt8]) throws(PostgresError) {
        var offset = 0
        while offset < bytes.count {
            offset += try sendChunk(bytes, from: offset)
        }
    }

    private func sendChunk(_ bytes: [UInt8], from offset: Int) throws(PostgresError) -> Int {
        let written = bytes.withUnsafeBytes { raw in
            send(descriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset, Int32(MSG_NOSIGNAL))
        }
        guard written > 0 else { throw PostgresError.transportError(reason: "blocking send failed") }
        return written
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

    private func fillReadBuffer() throws(PostgresError) {
        let received = scratch.withUnsafeMutableBytes { raw in
            recv(descriptor, raw.baseAddress, raw.count, 0)
        }
        guard received > 0 else { throw PostgresError.connectionClosed }
        readBuffer.writeBytes(scratch[0..<received])
    }

    private func reclaimReadBuffer() {
        guard readBuffer.readerIndex > 16 * 1024, readBuffer.readableBytes == 0 else { return }
        readBuffer.clear()
    }

    func query(_ sql: String, parameters: [PostgresCell]) throws(PostgresError) -> PostgresQueryResult {
        let plan = planStatement(for: sql)
        do {
            writeScratch.clear()
            buildExtended(plan: plan, sql: sql, parameters: parameters, into: &writeScratch)
            try writeAll(writeScratch)
            return try collectResult()
        } catch {
            preparedStatements.removeValue(forKey: sql)
            throw error
        }
    }

    private func collectResult() throws(PostgresError) -> PostgresQueryResult {
        var accumulator = ResultAccumulator()
        while true {
            if try accumulator.absorb(nextMessage()) { return try accumulator.result() }
        }
    }

    private enum Plan {

        case prepared(name: String)
        case parse(name: String)
    }

    private func planStatement(for sql: String) -> Plan {
        if let name = preparedStatements[sql] { return .prepared(name: name) }
        statementCounter += 1
        let name = "dxb\(statementCounter)"
        preparedStatements[sql] = name
        return .parse(name: name)
    }

    // Builds the whole Parse/Bind/Describe/Execute/Sync exchange directly into the
    // reused write buffer: one allocation reused across queries, no throwaway
    // per-message buffers and no inter-message copies.
    private func buildExtended(plan: Plan, sql: String, parameters: [PostgresCell], into buffer: inout ByteBuffer) {
        let name = appendParseIfNeeded(plan, sql: sql, into: &buffer)
        FrontendMessage.appendBind(into: &buffer, portalName: "", statementName: name, parameters: parameters)
        FrontendMessage.appendDescribePortal(into: &buffer, name: "")
        FrontendMessage.appendExecute(into: &buffer, portalName: "", maxRows: 0)
        FrontendMessage.appendSync(into: &buffer)
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
