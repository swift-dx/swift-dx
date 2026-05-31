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

import Atomics
import DXCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle

final class JetStreamClientImpl: JetStreamClient, JetStreamConnection, Service {

    static func connect(_ configuration: JetStreamConfiguration) async throws(JetStreamError) -> JetStreamClientImpl {
        let impl = JetStreamClientImpl(group: configuration.eventLoopGroup, credentials: configuration.credentials, logger: configuration.logger)
        try await impl.connect(endpoint: configuration.endpoint)
        return impl
    }

    func run() async throws {
        try await gracefulShutdown()
        await close()
    }


    let inboxPrefix: String
    let inboxPrefixBytes: [UInt8]

    let counter: ManagedAtomic<UInt64>
    let sidCounter: ManagedAtomic<UInt64>
    let sharedInboxSid: ManagedAtomic<UInt64>

    private let group: EventLoopGroup
    private let credentialsSource: NatsCredentialsSource
    private let logger: NatsLogger
    private let connectionState: NIOLockedValueBox<ConnectionState>
    private let resolvedCredentials: NIOLockedValueBox<ResolvedCredentials>
    private let pendingRequests: NIOLockedValueBox<[String: PendingSingle]>
    private let pendingBySid: NIOLockedValueBox<[UInt64: PendingFetch]>
    private let activeBarriers: NIOLockedValueBox<[ActiveBarrier]>
    private let fetchStreams: NIOLockedValueBox<[UInt64: FetchStream]>

    // Hot-path cache for dispatchBarrierByRange. Written and read only from the
    // channel's event loop thread (via InboundHandler), so no synchronisation is
    // needed. A stale hint is harmless: a non-matching suffix falls through to
    // the locked lookup; a matching-but-already-completed barrier absorbs an
    // extra arrive() that PendingBarrier handles as a no-op.
    nonisolated(unsafe) private var lastBarrierHint: BarrierHint = .empty

    private enum BarrierHint: Sendable {

        case empty
        case set(ActiveBarrier)
    }

    private struct ConnectionState {

        var phase: Phase
        var connectSent: Bool
    }

    private enum Phase {

        case unconnected
        case connecting(channel: Channel, handshake: EventLoopPromise<Void>)
        case connected(channel: Channel)
        case closed
    }

    private enum ChannelLookup {

        case channel(Channel)
        case unavailable
    }

    private enum HandshakeAction {

        case nothing
        case succeed(EventLoopPromise<Void>, Channel)
        case fail(EventLoopPromise<Void>, any Error)
    }

    init(group: EventLoopGroup, credentials: NatsCredentialsSource = .anonymous, logger: NatsLogger = .silent) {
        self.group = group
        self.credentialsSource = credentials
        self.logger = logger
        let prefix = InboxGenerator.newPrefix()
        self.inboxPrefix = prefix
        self.inboxPrefixBytes = Array(prefix.utf8)
        self.counter = ManagedAtomic<UInt64>(0)
        self.sidCounter = ManagedAtomic<UInt64>(0)
        self.sharedInboxSid = ManagedAtomic<UInt64>(0)
        self.connectionState = NIOLockedValueBox(ConnectionState(phase: .unconnected, connectSent: false))
        self.resolvedCredentials = NIOLockedValueBox(.anonymous)
        self.pendingRequests = NIOLockedValueBox([:])
        self.pendingBySid = NIOLockedValueBox([:])
        self.activeBarriers = NIOLockedValueBox([])
        self.fetchStreams = NIOLockedValueBox([:])
    }

    func connect(endpoint: NatsEndpoint) async throws(JetStreamError) {
        logger.emit(.connecting(endpoint: endpoint))
        let resolved = try CredentialsLoader.resolve(credentialsSource)
        resolvedCredentials.withLockedValue { $0 = resolved }
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_sndbuf), value: 4 * 1024 * 1024)
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4 * 1024 * 1024)
            .channelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 256 * 1024, high: 4 * 1024 * 1024))
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 256 * 1024))
            .channelInitializer { [weakConnection = WeakBox(self)] channel in
                guard let owner = weakConnection.value else {
                    return channel.eventLoop.makeFailedFuture(JetStreamError.notConnected)
                }
                return channel.pipeline.addHandler(InboundHandler(connection: owner))
            }
        let channel = try await execute { try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get() }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        connectionState.withLockedValue { state in
            state.phase = .connecting(channel: channel, handshake: promise)
            state.connectSent = false
        }
        try await execute { try await promise.futureResult.get() }
        let sid = sidCounter.wrappingIncrementThenLoad(ordering: .relaxed)
        sharedInboxSid.store(sid, ordering: .releasing)
        let sub = FrameBuilder.buildSubscribe(inbox: "\(inboxPrefix).*", sid: sid)
        try await write(sub)
        logger.emit(.connected(endpoint: endpoint))
    }

    func buildConnectFrame(nonce: String) throws(JetStreamError) -> [UInt8] {
        logger.emit(.handshakeReceivedInfo)
        let resolved = resolvedCredentials.withLockedValue { $0 }
        switch resolved {
        case .anonymous: return buildAnonymousConnectFrame()
        case .authenticated(let jwt, let signer): return try buildAuthenticatedConnectFrame(jwt: jwt, signer: signer, nonce: nonce)
        }
    }

    private func buildAnonymousConnectFrame() -> [UInt8] {
        logger.emit(.handshakeAnonymousSent)
        return FrameBuilder.buildAnonymousConnect()
    }

    private func buildAuthenticatedConnectFrame(jwt: String, signer: Ed25519Signer, nonce: String) throws(JetStreamError) -> [UInt8] {
        guard !nonce.isEmpty else { throw JetStreamError.credentialsNonceMissing }
        let signature = try signer.sign(nonce: nonce)
        logger.emit(.handshakeAuthenticatedSent)
        return FrameBuilder.buildAuthenticatedConnect(jwt: jwt, signature: signature)
    }

    func close() async {
        let outcome: ChannelExtractionForClose = connectionState.withLockedValue { state in
            switch state.phase {
            case .connected(let channel), .connecting(let channel, _):
                state.phase = .closed
                return .extracted(channel)
            case .unconnected, .closed:
                state.phase = .closed
                return .alreadyClosed
            }
        }
        switch outcome {
        case .extracted(let channel):
            do {
                try await channel.close()
            } catch {
                logger.emitError(.errorRaised(reason: "channel close failed: \(error)"))
            }
        case .alreadyClosed:
            break
        }
        logger.emit(.disconnected)
    }

    private enum ChannelExtractionForClose {
        case extracted(Channel)
        case alreadyClosed
    }

    func enqueue(to subject: Subject, payloads: [[UInt8]]) -> PublishHandle {
        let traceHeaders = TracePropagation.injectCurrent()
        if traceHeaders.isEmpty {
            return enqueuePlain(to: subject, payloads: payloads)
        }
        let messages = payloads.map { NatsOutgoingMessage(dedup: .noDedup, headers: traceHeaders, payload: $0) }
        return enqueueWithHeadersAlreadyMerged(to: subject, messages: messages)
    }

    private func enqueuePlain(to subject: Subject, payloads: [[UInt8]]) -> PublishHandle {
        let count = payloads.count
        let barrier = PendingBarrier(count: count)
        let new = counter.wrappingIncrementThenLoad(by: UInt64(count), ordering: .acquiringAndReleasing)
        let lo = new - UInt64(count) + 1
        let hi = lo + UInt64(count)
        encodeAndDispatchPlain(subject: subject.value, payloads: payloads, loSuffix: lo, hiSuffix: hi, barrier: barrier)
        if !logger.isSilent {
            logger.emit(.publishStarted(traceId: NatsTraceId(value: lo), subject: subject.value, count: count))
        }
        return PublishHandle(traceId: NatsTraceId(value: lo), barrier: barrier, loSuffix: lo, connection: self)
    }

    func publish(to subject: Subject, payloads: [[UInt8]]) async throws(JetStreamError) {
        let handle = enqueue(to: subject, payloads: payloads)
        try await handle.wait()
    }

    func enqueue(to subject: Subject, messages: [NatsOutgoingMessage]) -> PublishHandle {
        let traceHeaders = TracePropagation.injectCurrent()
        if traceHeaders.isEmpty {
            return enqueueWithHeadersAlreadyMerged(to: subject, messages: messages)
        }
        let merged = messages.map { NatsOutgoingMessage(dedup: $0.dedup, headers: traceHeaders + $0.headers, payload: $0.payload) }
        return enqueueWithHeadersAlreadyMerged(to: subject, messages: merged)
    }

    private func enqueueWithHeadersAlreadyMerged(to subject: Subject, messages: [NatsOutgoingMessage]) -> PublishHandle {
        let barrier = PendingBarrier(count: messages.count)
        let new = counter.wrappingIncrementThenLoad(by: UInt64(messages.count), ordering: .acquiringAndReleasing)
        let lo = new - UInt64(messages.count) + 1
        let hi = lo + UInt64(messages.count)
        let traceId = NatsTraceId(value: lo)
        if !logger.isSilent {
            logger.emit(.publishStarted(traceId: traceId, subject: subject.value, count: messages.count))
        }
        encodeAndDispatchWithIds(subject: subject.value, messages: messages, loSuffix: lo, hiSuffix: hi, barrier: barrier)
        return PublishHandle(traceId: traceId, barrier: barrier, loSuffix: lo, connection: self)
    }

    func publish(to subject: Subject, messages: [NatsOutgoingMessage]) async throws(JetStreamError) {
        let handle = enqueue(to: subject, messages: messages)
        try await handle.wait()
    }

    func fetch(from stream: StreamName, for consumer: ConsumerName, needsPayload: Bool) async throws(JetStreamError) -> FetchStream {
        let sid = sidCounter.wrappingIncrementThenLoad(ordering: .relaxed)
        let id = counter.wrappingIncrementThenLoad(ordering: .relaxed)
        let inbox = "\(inboxPrefix).fs.\(String(id, radix: 36))"
        let pubSubject = "$JS.API.CONSUMER.MSG.NEXT.\(stream.value).\(consumer.value)"
        let fetchStream = FetchStream(sid: sid, inbox: inbox, needsPayload: needsPayload, pubSubject: pubSubject, connection: self)
        fetchStreams.withLockedValue { $0[sid] = fetchStream }
        let subFrame = FrameBuilder.buildSubscribe(inbox: inbox, sid: sid)
        try await write(subFrame)
        logger.emit(.fetchOpened(stream: stream.value, consumer: consumer.value))
        return fetchStream
    }

    func close(_ stream: FetchStream) async {
        stream.close()
        fetchStreams.withLockedValue { _ = $0.removeValue(forKey: stream.sid) }
        let unsubFrame = FrameBuilder.buildUnsubscribe(sid: stream.sid)
        do {
            try await write(unsubFrame)
        } catch {
            logger.emitError(.errorRaised(reason: "unsubscribe write failed: \(error)"))
        }
        logger.emit(.fetchClosed)
    }

    func messages(from streamName: StreamName, for consumer: ConsumerName, options: PullOptions) -> AsyncThrowingStream<NatsMessage, any Error> {
        let (asyncStream, continuation) = AsyncThrowingStream<NatsMessage, any Error>.makeStream()
        let task = Task { [self] in
            await runPullLoop(streamName: streamName, consumer: consumer, options: options, continuation: continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        return asyncStream
    }

    private func runPullLoop(streamName: StreamName, consumer: ConsumerName, options: PullOptions, continuation: AsyncThrowingStream<NatsMessage, any Error>.Continuation) async {
        let fetchStream: FetchStream
        do {
            fetchStream = try await fetch(from: streamName, for: consumer, needsPayload: true)
        } catch {
            logger.emitError(.errorRaised(reason: "fetch setup failed: \(error)"))
            continuation.finish(throwing: error)
            return
        }
        await drainPullLoop(fetchStream: fetchStream, options: options, continuation: continuation)
        await close(fetchStream)
    }

    private func drainPullLoop(fetchStream: FetchStream, options: PullOptions, continuation: AsyncThrowingStream<NatsMessage, any Error>.Continuation) async {
        do {
            try await pumpUntilCancelled(fetchStream: fetchStream, options: options, continuation: continuation)
            continuation.finish()
        } catch let typed as JetStreamError {
            logger.emitError(.errorRaised(reason: "pull pump failed: \(typed)"))
            continuation.finish(throwing: typed)
        } catch {
            logger.emitError(.errorRaised(reason: "pull pump transport error: \(error)"))
            continuation.finish(throwing: JetStreamError.transportError(reason: "\(error)"))
        }
    }

    private func pumpUntilCancelled(fetchStream: FetchStream, options: PullOptions, continuation: AsyncThrowingStream<NatsMessage, any Error>.Continuation) async throws {
        while !Task.isCancelled {
            let result = try await fetchStream.requestAndAwait(batch: options.batch, expires: options.expires, wait: options.wait)
            yieldBatch(result: result, sid: fetchStream.sid, continuation: continuation)
        }
    }

    private func yieldBatch(result: FetchStream.Result, sid: UInt64, continuation: AsyncThrowingStream<NatsMessage, any Error>.Continuation) {
        for index in 0..<result.replies.count {
            continuation.yield(buildYieldMessage(result: result, sid: sid, index: index))
        }
    }

    private func buildYieldMessage(result: FetchStream.Result, sid: UInt64, index: Int) -> NatsMessage {
        let payload = index < result.payloads.count ? result.payloads[index] : []
        return NatsMessage(
            subject: String(decoding: result.subjects[index], as: UTF8.self),
            sid: sid,
            reply: .subject(String(decoding: result.replies[index], as: UTF8.self)),
            headers: result.headers[index],
            payload: payload,
            status: .ok
        )
    }

    func ack(_ message: NatsMessage) {
        switch message.reply {
        case .none:
            return
        case .subject(let replySubject):
            acknowledge(replies: [Array(replySubject.utf8)])
        }
    }

    @inline(__always)
    func acknowledge(replies: [[UInt8]]) {
        let allocator: ByteBufferAllocator
        switch currentChannelLookup() {
        case .channel(let channel):
            allocator = channel.allocator
        case .unavailable:
            allocator = ByteBufferAllocator()
        }
        let buf = FrameBuilder.buildAckBatch(allocator: allocator, replies: replies)
        writeBufNonBlocking(buf)
    }

    func nak(_ message: NatsMessage) {
        guard case .reply(let reply) = ackTarget(of: message) else { return }
        writeBytesNonBlocking(FrameBuilder.buildNak(reply: reply))
    }

    func nak(_ message: NatsMessage, delay: TimeSpan) {
        guard case .reply(let reply) = ackTarget(of: message) else { return }
        writeBytesNonBlocking(FrameBuilder.buildNak(reply: reply, delayNanoseconds: delay.nanoseconds))
    }

    func term(_ message: NatsMessage) {
        guard case .reply(let reply) = ackTarget(of: message) else { return }
        writeBytesNonBlocking(FrameBuilder.buildTerm(reply: reply))
    }

    func term(_ message: NatsMessage, reason: String) {
        guard case .reply(let reply) = ackTarget(of: message) else { return }
        writeBytesNonBlocking(FrameBuilder.buildTerm(reply: reply, reason: reason))
    }

    func inProgress(_ message: NatsMessage) {
        guard case .reply(let reply) = ackTarget(of: message) else { return }
        writeBytesNonBlocking(FrameBuilder.buildInProgress(reply: reply))
    }

    private func ackTarget(of message: NatsMessage) -> AckTarget {
        switch message.reply {
        case .none:
            return .skip
        case .subject(let replySubject):
            return .reply(Array(replySubject.utf8))
        }
    }

    private enum AckTarget {

        case skip
        case reply([UInt8])
    }

    func request(at subject: Subject, payload: [UInt8]) async throws(JetStreamError) -> NatsMessage {
        let id = counter.wrappingIncrementThenLoad(ordering: .relaxed)
        let reply = "\(inboxPrefix).\(String(id, radix: 36))"
        let pending = PendingSingle()
        pendingRequests.withLockedValue { $0[reply] = pending }
        let frame = FrameBuilder.buildSingleRequest(subject: subject.value, reply: reply, payload: payload)
        try await write(frame)
        let message = try await execute { try await pending.wait() }
        pendingRequests.withLockedValue { _ = $0.removeValue(forKey: reply) }
        return message
    }

    func ensure(_ stream: StreamName, subject: Subject, storage: StorageMode = .file) async throws(JetStreamError) {
        let storageString = storage == .file ? "file" : "memory"
        let json = "{\"name\":\"\(stream.value)\",\"subjects\":[\"\(subject.value)\"],\"storage\":\"\(storageString)\"}"
        let apiSubject = try Subject("$JS.API.STREAM.CREATE.\(stream.value)")
        _ = try await request(at: apiSubject, payload: Array(json.utf8))
        logger.emit(.streamEnsured(name: stream.value))
    }

    func delete(_ stream: StreamName) async throws(JetStreamError) {
        let apiSubject = try Subject("$JS.API.STREAM.DELETE.\(stream.value)")
        _ = try await request(at: apiSubject, payload: [])
        logger.emit(.streamDeleted(name: stream.value))
    }

    func ensure(_ consumer: ConsumerName, on stream: StreamName, configuration: ConsumerConfiguration) async throws(JetStreamError) {
        let ackWaitNanos = configuration.ackWait.nanoseconds
        let ackPolicyString = ackPolicyJSONValue(configuration.ackPolicy)
        let maxDeliverValue = deliveryAttemptLimitJSONValue(configuration.deliveryAttemptLimit)
        let filterSubjectValue = subjectMatchJSONValue(configuration.subjectFilter)
        let json = "{\"stream_name\":\"\(stream.value)\",\"config\":{\"durable_name\":\"\(consumer.value)\",\"ack_policy\":\"\(ackPolicyString)\",\"ack_wait\":\(ackWaitNanos),\"max_ack_pending\":\(configuration.maxAckPending),\"filter_subject\":\"\(filterSubjectValue)\",\"max_deliver\":\(maxDeliverValue)}}"
        let apiSubject = try Subject("$JS.API.CONSUMER.CREATE.\(stream.value).\(consumer.value)")
        _ = try await request(at: apiSubject, payload: Array(json.utf8))
        logger.emit(.consumerEnsured(stream: stream.value, consumer: consumer.value))
    }

    @inline(__always)
    private func deliveryAttemptLimitJSONValue(_ limit: DeliveryAttemptLimit) -> Int {
        switch limit {
        case .unlimited: return -1
        case .max(let value): return value
        }
    }

    @inline(__always)
    private func subjectMatchJSONValue(_ match: SubjectMatch) -> String {
        switch match {
        case .any: return ""
        case .pattern(let subject): return subject.value
        }
    }

    @inline(__always)
    private func ackPolicyJSONValue(_ policy: AckPolicy) -> String {
        switch policy {
        case .explicit: return "explicit"
        case .all: return "all"
        case .none: return "none"
        }
    }

    func emitPublishBatchAcked(traceId: NatsTraceId) {
        logger.emit(.publishAcked(traceId: traceId))
    }

    var sharedInboxSidValue: UInt64 {
        sharedInboxSid.load(ordering: .acquiring)
    }

    func signalHandshakeSuccess() {
        let action: HandshakeAction = connectionState.withLockedValue { state in
            switch state.phase {
            case .connecting(let channel, let promise):
                state.phase = .connected(channel: channel)
                return .succeed(promise, channel)
            case .connected, .unconnected, .closed:
                return .nothing
            }
        }
        if case .succeed(let promise, _) = action {
            logger.emit(.handshakeCompleted)
            promise.succeed(())
        }
    }

    func signalHandshakeFailed(_ error: any Error) {
        let action: HandshakeAction = connectionState.withLockedValue { state in
            switch state.phase {
            case .connecting(_, let promise):
                state.phase = .closed
                return .fail(promise, error)
            case .connected, .unconnected, .closed:
                return .nothing
            }
        }
        if case .fail(let promise, let error) = action {
            logger.emitError(.handshakeFailed(reason: "\(error)"))
            promise.fail(error)
        }
    }

    func tryMarkConnectSent() -> Bool {
        connectionState.withLockedValue { state in
            if state.connectSent { return false }
            state.connectSent = true
            return true
        }
    }

    func unregisterBarrier(loSuffix: UInt64) {
        activeBarriers.withLockedValue { entries in
            if let index = entries.firstIndex(where: { $0.lo == loSuffix }) {
                entries.remove(at: index)
            }
        }
    }

    @inline(__always)
    func dispatchBarrierByRange(suffix: UInt64) -> Bool {
        if hintMatchesAndArrives(suffix: suffix) {
            return true
        }
        return dispatchFromActiveSlow(suffix: suffix)
    }

    @inline(__always)
    private func hintMatchesAndArrives(suffix: UInt64) -> Bool {
        guard case .set(let cached) = lastBarrierHint else { return false }
        guard suffix >= cached.lo, suffix < cached.hi else { return false }
        arriveAndUpdateHint(cached)
        return true
    }

    private func dispatchFromActiveSlow(suffix: UInt64) -> Bool {
        switch lookupActiveBarrier(suffix: suffix) {
        case .found(let entry):
            arriveAndUpdateHint(entry)
            return true
        case .notFound:
            return false
        }
    }

    private func lookupActiveBarrier(suffix: UInt64) -> BarrierLookup {
        activeBarriers.withLockedValue { entries in
            for entry in entries {
                if suffix >= entry.lo, suffix < entry.hi {
                    return .found(entry)
                }
            }
            return .notFound
        }
    }

    private func arriveAndUpdateHint(_ entry: ActiveBarrier) {
        if entry.barrier.arrive() {
            lastBarrierHint = .empty
        } else {
            lastBarrierHint = .set(entry)
        }
    }

    private enum BarrierLookup {

        case found(ActiveBarrier)
        case notFound
    }

    func fetchNeedsPayload(sid: UInt64) -> Bool {
        enum Found {
            case missing
            case needs(Bool)
        }
        let pendingFound: Found = pendingBySid.withLockedValue { table in
            if let pending = table[sid] {
                return .needs(pending.needsPayload)
            }
            return .missing
        }
        if case .needs(let value) = pendingFound { return value }
        let streamFound: Found = fetchStreams.withLockedValue { table in
            if let stream = table[sid] {
                return .needs(stream.needsPayload)
            }
            return .missing
        }
        if case .needs(let value) = streamFound { return value }
        return false
    }

    @inline(__always)
    func dispatchFetchStream(sid: UInt64, subject: [UInt8], reply: [UInt8], headers: [NatsHeader], payload: [UInt8], status: NatsMessageStatus) -> Bool {
        let stream = fetchStreams.withLockedValue { $0[sid] }
        guard let stream else { return false }
        switch status {
        case .code(let code):
            stream.deliverStatus(code)
        case .ok:
            if stream.needsPayload {
                stream.deliverReplyAndPayload(subject: subject, reply: reply, headers: headers, payload: payload)
            } else {
                stream.deliverReply(subject: subject, reply: reply, headers: headers)
            }
        }
        return true
    }

    @inline(__always)
    func dispatchFetchBySid(sid: UInt64, subject: [UInt8], reply: [UInt8], headers: [NatsHeader], payload: [UInt8], status: NatsMessageStatus) -> Bool {
        let pending = pendingBySid.withLockedValue { $0[sid] }
        guard let pending else { return false }
        let done = deliverToPending(pending, reply: reply, payload: payload, status: status)
        if done { removePending(sid: sid) }
        return true
    }

    private func deliverToPending(_ pending: PendingFetch, reply: [UInt8], payload: [UInt8], status: NatsMessageStatus) -> Bool {
        switch status {
        case .code(let code): return pending.deliverStatus(code)
        case .ok: return deliverOk(pending: pending, reply: reply, payload: payload)
        }
    }

    @inline(__always)
    private func deliverOk(pending: PendingFetch, reply: [UInt8], payload: [UInt8]) -> Bool {
        pending.needsPayload
            ? pending.deliverReplyAndPayload(reply, payload: payload)
            : pending.deliverReply(reply)
    }

    private func removePending(sid: UInt64) {
        pendingBySid.withLockedValue { _ = $0.removeValue(forKey: sid) }
    }

    func dispatchSlow(subject: String, sid: UInt64, reply: ReplyAddress, headers: [NatsHeader], payload: [UInt8]) {
        if sid == sharedInboxSidValue {
            enum Found {
                case missing
                case found(PendingSingle)
            }
            let found: Found = pendingRequests.withLockedValue { table in
                if let pending = table.removeValue(forKey: subject) { return .found(pending) }
                return .missing
            }
            if case .found(let pending) = found {
                pending.complete(.success(NatsMessage(subject: subject, sid: sid, reply: reply, headers: headers, payload: payload, status: .ok)))
            }
            return
        }
        _ = dispatchFetchBySid(sid: sid, subject: Array(subject.utf8), reply: replyBytes(reply), headers: headers, payload: payload, status: .ok)
    }

    func writeBytesNonBlocking(_ bytes: [UInt8]) {
        switch currentChannelLookup() {
        case .channel(let channel):
            var buf = channel.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            channel.writeAndFlush(buf, promise: nil)
        case .unavailable:
            return
        }
    }

    @inline(__always)
    private func encodeAndDispatchPlain(subject: String, payloads: [[UInt8]], loSuffix: UInt64, hiSuffix: UInt64, barrier: PendingBarrier) {
        let allocator: ByteBufferAllocator
        switch currentChannelLookup() {
        case .channel(let channel):
            allocator = channel.allocator
        case .unavailable:
            allocator = ByteBufferAllocator()
        }
        let buf = FrameBuilder.buildPublishBatchPlain(
            allocator: allocator,
            subject: subject,
            inboxPrefixBytes: inboxPrefixBytes,
            payloads: payloads,
            loSuffix: loSuffix
        )
        activeBarriers.withLockedValue { $0.append(ActiveBarrier(lo: loSuffix, hi: hiSuffix, barrier: barrier)) }
        writeBufNonBlocking(buf)
    }

    @inline(__always)
    private func encodeAndDispatchWithIds(subject: String, messages: [NatsOutgoingMessage], loSuffix: UInt64, hiSuffix: UInt64, barrier: PendingBarrier) {
        let allocator: ByteBufferAllocator
        switch currentChannelLookup() {
        case .channel(let channel):
            allocator = channel.allocator
        case .unavailable:
            allocator = ByteBufferAllocator()
        }
        let buf = FrameBuilder.buildPublishBatchWithIds(
            allocator: allocator,
            subject: subject,
            inboxPrefixBytes: inboxPrefixBytes,
            messages: messages,
            loSuffix: loSuffix
        )
        activeBarriers.withLockedValue { $0.append(ActiveBarrier(lo: loSuffix, hi: hiSuffix, barrier: barrier)) }
        writeBufNonBlocking(buf)
    }

    private func write(_ bytes: [UInt8]) async throws(JetStreamError) {
        let channel = try requireChannel()
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        try await execute { try await channel.writeAndFlush(buf) }
    }

    private func writeBufNonBlocking(_ buf: ByteBuffer) {
        switch currentChannelLookup() {
        case .channel(let channel):
            channel.writeAndFlush(buf, promise: nil)
        case .unavailable:
            return
        }
    }

    private func currentChannelLookup() -> ChannelLookup {
        connectionState.withLockedValue { state in
            switch state.phase {
            case .connecting(let channel, _), .connected(let channel):
                return .channel(channel)
            case .unconnected, .closed:
                return .unavailable
            }
        }
    }

    private func requireChannel() throws(JetStreamError) -> Channel {
        switch currentChannelLookup() {
        case .channel(let channel):
            return channel
        case .unavailable:
            throw JetStreamError.notConnected
        }
    }

    private func replyBytes(_ reply: ReplyAddress) -> [UInt8] {
        switch reply {
        case .none:
            return []
        case .subject(let value):
            return Array(value.utf8)
        }
    }
}

// Safe across threads because the only stored property is a `weak` reference;
// reads observe either the live object or nil, both atomic at the runtime
// level, and no mutation is exposed.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {

    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}
