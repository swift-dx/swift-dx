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
import Logging
import NIOConcurrencyHelpers
import NIOCore

// Owns subscribe-mode connectivity for one client. Registrations (channel or
// pattern subscriptions and their handlers) live behind a lock and outlive the
// connection. A single background reconcile loop owns the connection: it opens
// it on demand, re-subscribes the whole registered set after a drop with capped
// backoff, and tears everything down on shutdown. Inbound push frames are routed
// straight from the event loop into each registration's bounded async stream
// (non-blocking), and a per-registration consumer task awaits the handler in
// order. A subscription survives reconnects until it is explicitly cancelled.
final class RedisSubscriptionManager: Sendable {

    struct Configuration: Sendable {

        let endpoint: RedisEndpoint
        let credentials: RedisCredentials
        let transportSecurity: RedisTransportSecurity
        let eventLoopGroup: EventLoopGroup
        let connectTimeout: TimeAmount
        let reconnectBaseDelay: TimeAmount
        let reconnectMaxDelay: TimeAmount
        let depthLimit: Int
        let maxBulkBytes: Int
        let deliveryBufferSize: Int
    }

    private enum Target {

        case channels(Set<String>)
        case patterns(Set<String>)
    }

    private struct Registration {

        let target: Target
        let continuation: AsyncStream<RedisSubscriptionDelivery>.Continuation
        let consumer: Task<Void, Never>
    }

    private enum ConnectionSlot {

        case none
        case live(RedisSubscriptionConnection)
    }

    private struct State {

        var registrations: [UInt64: Registration] = [:]
        var channelSubscribers: [String: Set<UInt64>] = [:]
        var patternSubscribers: [String: Set<UInt64>] = [:]
        var connection: ConnectionSlot = .none
        var wireChannels: Set<String> = []
        var wirePatterns: Set<String> = []
        var nextId: UInt64 = 1
        var isClosed = false
    }

    private enum SubscribeOutcome {

        case closed
        case registered(UInt64)
    }

    private enum CancelOutcome {

        case notFound
        case removed(Registration)
    }

    private let configuration: Configuration
    private let logger: Logger
    private let state = NIOLockedValueBox(State())
    private let droppedMessages = ManagedAtomic<Int>(0)
    let events: AsyncStream<Void>
    private let eventsContinuation: AsyncStream<Void>.Continuation

    init(configuration: Configuration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(16))
        self.events = stream
        self.eventsContinuation = continuation
    }

    func wake() {
        eventsContinuation.yield()
    }

    func start() {
        Task { await self.runMaintainLoop() }
    }

    func subscribe(channels: [RedisChannel], handler: @escaping @Sendable (RedisChannel, RedisMessage) async throws -> Void) throws(RedisError) -> RedisSubscription {
        let names = Set(channels.map(\.name))
        let (stream, continuation) = AsyncStream.makeStream(of: RedisSubscriptionDelivery.self, bufferingPolicy: .bufferingNewest(configuration.deliveryBufferSize))
        let consumer = makeChannelConsumer(stream, handler: handler)
        let outcome = register(target: .channels(names), continuation: continuation, consumer: consumer) { state, id in
            for name in names { state.channelSubscribers[name, default: []].insert(id) }
        }
        return try finishSubscribe(outcome, continuation: continuation, consumer: consumer)
    }

    func subscribe(patterns: [RedisPattern], handler: @escaping @Sendable (RedisPattern, RedisChannel, RedisMessage) async throws -> Void) throws(RedisError) -> RedisSubscription {
        let values = Set(patterns.map(\.value))
        let (stream, continuation) = AsyncStream.makeStream(of: RedisSubscriptionDelivery.self, bufferingPolicy: .bufferingNewest(configuration.deliveryBufferSize))
        let consumer = makePatternConsumer(stream, handler: handler)
        let outcome = register(target: .patterns(values), continuation: continuation, consumer: consumer) { state, id in
            for value in values { state.patternSubscribers[value, default: []].insert(id) }
        }
        return try finishSubscribe(outcome, continuation: continuation, consumer: consumer)
    }

    private func makeChannelConsumer(_ stream: AsyncStream<RedisSubscriptionDelivery>, handler: @escaping @Sendable (RedisChannel, RedisMessage) async throws -> Void) -> Task<Void, Never> {
        let logger = self.logger
        return Task {
            for await delivery in stream {
                guard case .channel(let channel, let message) = delivery else { continue }
                do {
                    try await handler(channel, message)
                } catch {
                    logger.warning("Redis subscription handler threw", metadata: ["channel": .string(channel.name), "error": .string(String(describing: error))])
                }
            }
        }
    }

    private func makePatternConsumer(_ stream: AsyncStream<RedisSubscriptionDelivery>, handler: @escaping @Sendable (RedisPattern, RedisChannel, RedisMessage) async throws -> Void) -> Task<Void, Never> {
        let logger = self.logger
        return Task {
            for await delivery in stream {
                guard case .pattern(let pattern, let channel, let message) = delivery else { continue }
                do {
                    try await handler(pattern, channel, message)
                } catch {
                    logger.warning("Redis subscription handler threw", metadata: ["pattern": .string(pattern.value), "channel": .string(channel.name), "error": .string(String(describing: error))])
                }
            }
        }
    }

    private func register(target: Target, continuation: AsyncStream<RedisSubscriptionDelivery>.Continuation, consumer: Task<Void, Never>, index: (inout State, UInt64) -> Void) -> SubscribeOutcome {
        state.withLockedValue { state in
            guard !state.isClosed else { return .closed }
            let id = state.nextId
            state.nextId += 1
            state.registrations[id] = Registration(target: target, continuation: continuation, consumer: consumer)
            index(&state, id)
            return .registered(id)
        }
    }

    private func finishSubscribe(_ outcome: SubscribeOutcome, continuation: AsyncStream<RedisSubscriptionDelivery>.Continuation, consumer: Task<Void, Never>) throws(RedisError) -> RedisSubscription {
        switch outcome {
        case .closed:
            continuation.finish()
            consumer.cancel()
            throw RedisError.poolShutdown
        case .registered(let id):
            wake()
            return RedisSubscription(id: id, manager: self)
        }
    }

    func cancel(_ id: UInt64) {
        let outcome = state.withLockedValue { state in removeRegistration(id, from: &state) }
        guard case .removed(let registration) = outcome else { return }
        registration.continuation.finish()
        registration.consumer.cancel()
        wake()
    }

    private func removeRegistration(_ id: UInt64, from state: inout State) -> CancelOutcome {
        guard let registration = state.registrations.removeValue(forKey: id) else { return .notFound }
        switch registration.target {
        case .channels(let names): unindex(names, id: id, from: &state.channelSubscribers)
        case .patterns(let values): unindex(values, id: id, from: &state.patternSubscribers)
        }
        return .removed(registration)
    }

    private func unindex(_ keys: Set<String>, id: UInt64, from index: inout [String: Set<UInt64>]) {
        for key in keys {
            index[key]?.remove(id)
            if index[key]?.isEmpty == true { index[key] = nil }
        }
    }

    func shutdown() async {
        let (registrations, connection) = state.withLockedValue { state -> ([Registration], ConnectionSlot) in
            state.isClosed = true
            let registrations = Array(state.registrations.values)
            let connection = state.connection
            state.registrations = [:]
            state.channelSubscribers = [:]
            state.patternSubscribers = [:]
            state.connection = .none
            return (registrations, connection)
        }
        for registration in registrations {
            registration.continuation.finish()
            registration.consumer.cancel()
        }
        if case .live(let live) = connection { await live.close() }
        eventsContinuation.finish()
    }

    func handleFrame(_ value: RESPValue) {
        guard case .array(let elements) = value else { return }
        dispatch(elements)
    }

    private func dispatch(_ elements: [RESPValue]) {
        guard let first = elements.first, case .bulkString(let kindBuffer) = first else { return }
        route(kind: kindBuffer.readableBytesView, elements: elements)
    }

    private func route(kind: ByteBufferView, elements: [RESPValue]) {
        if kind.elementsEqual("message".utf8) { deliverChannelFrame(elements); return }
        if kind.elementsEqual("pmessage".utf8) { deliverPatternFrame(elements) }
    }

    private func deliverChannelFrame(_ elements: [RESPValue]) {
        guard elements.count == 3 else { return }
        deliverChannel(elements[1], payload: elements[2])
    }

    private func deliverPatternFrame(_ elements: [RESPValue]) {
        guard elements.count == 4 else { return }
        deliverPattern(elements[1], channel: elements[2], payload: elements[3])
    }

    private func deliverChannel(_ channelFrame: RESPValue, payload: RESPValue) {
        guard case .bulkString(let channelBuffer) = channelFrame, case .bulkString(let payloadBuffer) = payload else { return }
        let channel = RedisChannel(String(decoding: channelBuffer.readableBytesView, as: UTF8.self))
        let delivery = RedisSubscriptionDelivery.channel(channel, RedisMessage(buffer: payloadBuffer))
        yieldToChannel(channel.name, delivery: delivery)
    }

    private func deliverPattern(_ patternFrame: RESPValue, channel channelFrame: RESPValue, payload: RESPValue) {
        guard case .bulkString(let patternBuffer) = patternFrame, case .bulkString(let channelBuffer) = channelFrame, case .bulkString(let payloadBuffer) = payload else { return }
        let pattern = RedisPattern(String(decoding: patternBuffer.readableBytesView, as: UTF8.self))
        let channel = RedisChannel(String(decoding: channelBuffer.readableBytesView, as: UTF8.self))
        let delivery = RedisSubscriptionDelivery.pattern(pattern, channel, RedisMessage(buffer: payloadBuffer))
        yieldToPattern(pattern.value, delivery: delivery)
    }

    private func yieldToChannel(_ name: String, delivery: RedisSubscriptionDelivery) {
        let dropped = state.withLockedValue { state in yield(delivery, to: state.channelSubscribers[name] ?? [], in: state) }
        recordDrops(dropped)
    }

    private func yieldToPattern(_ value: String, delivery: RedisSubscriptionDelivery) {
        let dropped = state.withLockedValue { state in yield(delivery, to: state.patternSubscribers[value] ?? [], in: state) }
        recordDrops(dropped)
    }

    private func yield(_ delivery: RedisSubscriptionDelivery, to ids: Set<UInt64>, in state: State) -> Int {
        var dropped = 0
        for id in ids {
            dropped += yieldOne(delivery, id: id, in: state)
        }
        return dropped
    }

    private func yieldOne(_ delivery: RedisSubscriptionDelivery, id: UInt64, in state: State) -> Int {
        guard let registration = state.registrations[id] else { return 0 }
        if case .dropped = registration.continuation.yield(delivery) { return 1 }
        return 0
    }

    private func recordDrops(_ dropped: Int) {
        guard dropped > 0 else { return }
        let total = droppedMessages.wrappingIncrementThenLoad(by: dropped, ordering: .relaxed)
        if shouldLogDrops(total: total, dropped: dropped) {
            logger.warning("Redis subscription buffer full; dropping messages", metadata: ["totalDropped": .stringConvertible(total)])
        }
    }

    private func shouldLogDrops(total: Int, dropped: Int) -> Bool {
        total == dropped || total % 10_000 < dropped
    }

    func signalConnectionLost() {
        wake()
    }
}

extension RedisSubscriptionManager {

    private enum ReconcileOutcome {

        case idle
        case retry
        case closed
    }

    private struct Snapshot: Sendable {

        let isClosed: Bool
        let channels: Set<String>
        let patterns: Set<String>
        let connection: ConnectionSlot
        let wireChannels: Set<String>
        let wirePatterns: Set<String>
    }

    func runMaintainLoop() async {
        var backoff = configuration.reconnectBaseDelay
        for await _ in events {
            let outcome = await reconcile()
            if case .closed = outcome { return }
            backoff = await advance(outcome, backoff: backoff)
        }
    }

    private func advance(_ outcome: ReconcileOutcome, backoff: TimeAmount) async -> TimeAmount {
        switch outcome {
        case .retry: await backoffThenRetry(backoff)
        case .idle: configuration.reconnectBaseDelay
        case .closed: backoff
        }
    }

    private func backoffThenRetry(_ backoff: TimeAmount) async -> TimeAmount {
        try? await Task.sleep(nanoseconds: UInt64(max(backoff.nanoseconds, 0)))
        wake()
        return min(.nanoseconds(backoff.nanoseconds &* 2), configuration.reconnectMaxDelay)
    }

    private func reconcile() async -> ReconcileOutcome {
        let snapshot = snapshotState()
        guard !snapshot.isClosed else { return .closed }
        switch snapshot.connection {
        case .none: return await reconcileDisconnected(snapshot)
        case .live(let connection): return await reconcileConnected(connection, snapshot)
        }
    }

    private func reconcileDisconnected(_ snapshot: Snapshot) async -> ReconcileOutcome {
        guard hasSubscriptions(snapshot) else { return .idle }
        do {
            let connection = try await openConnection()
            await storeAndSubscribeAll(connection, channels: snapshot.channels, patterns: snapshot.patterns)
            return .idle
        } catch {
            logger.warning("Redis subscription connect failed; retrying", metadata: ["error": .string(String(describing: error))])
            return .retry
        }
    }

    private func reconcileConnected(_ connection: RedisSubscriptionConnection, _ snapshot: Snapshot) async -> ReconcileOutcome {
        guard connection.isActive else {
            await dropConnection(connection)
            return .retry
        }
        guard hasSubscriptions(snapshot) else {
            await dropConnection(connection)
            return .idle
        }
        applyDiff(connection, snapshot)
        return .idle
    }

    private func hasSubscriptions(_ snapshot: Snapshot) -> Bool {
        !snapshot.channels.isEmpty || !snapshot.patterns.isEmpty
    }

    private func dropConnection(_ connection: RedisSubscriptionConnection) async {
        state.withLockedValue { state in
            guard case .live(let live) = state.connection, live === connection else { return }
            state.connection = .none
            state.wireChannels = []
            state.wirePatterns = []
        }
        await connection.close()
    }

    private func openConnection() async throws -> RedisSubscriptionConnection {
        try await RedisSubscriptionConnection.connect(
            endpoint: configuration.endpoint,
            credentials: configuration.credentials,
            transportSecurity: configuration.transportSecurity,
            eventLoopGroup: configuration.eventLoopGroup,
            connectTimeout: configuration.connectTimeout,
            depthLimit: configuration.depthLimit,
            maxBulkBytes: configuration.maxBulkBytes,
            onFrame: { [weak self] frame in self?.handleFrame(frame) },
            onClose: { [weak self] in self?.signalConnectionLost() }
        )
    }

    private func storeAndSubscribeAll(_ connection: RedisSubscriptionConnection, channels: Set<String>, patterns: Set<String>) async {
        let accepted = state.withLockedValue { state -> Bool in
            guard !state.isClosed else { return false }
            state.connection = .live(connection)
            state.wireChannels = channels
            state.wirePatterns = patterns
            return true
        }
        guard accepted else {
            await connection.close()
            return
        }
        subscribeAll(connection, channels: channels, patterns: patterns)
    }

    private func subscribeAll(_ connection: RedisSubscriptionConnection, channels: Set<String>, patterns: Set<String>) {
        if !channels.isEmpty { connection.send(Self.subscribeCommand(channels)) }
        if !patterns.isEmpty { connection.send(Self.psubscribeCommand(patterns)) }
    }

    private func applyDiff(_ connection: RedisSubscriptionConnection, _ snapshot: Snapshot) {
        sendChannelDiff(connection, add: snapshot.channels.subtracting(snapshot.wireChannels), remove: snapshot.wireChannels.subtracting(snapshot.channels))
        sendPatternDiff(connection, add: snapshot.patterns.subtracting(snapshot.wirePatterns), remove: snapshot.wirePatterns.subtracting(snapshot.patterns))
        state.withLockedValue { state in
            state.wireChannels = snapshot.channels
            state.wirePatterns = snapshot.patterns
        }
    }

    private func sendChannelDiff(_ connection: RedisSubscriptionConnection, add: Set<String>, remove: Set<String>) {
        if !add.isEmpty { connection.send(Self.subscribeCommand(add)) }
        if !remove.isEmpty { connection.send(Self.unsubscribeCommand(remove)) }
    }

    private func sendPatternDiff(_ connection: RedisSubscriptionConnection, add: Set<String>, remove: Set<String>) {
        if !add.isEmpty { connection.send(Self.psubscribeCommand(add)) }
        if !remove.isEmpty { connection.send(Self.punsubscribeCommand(remove)) }
    }

    private func snapshotState() -> Snapshot {
        state.withLockedValue { state in
            Snapshot(
                isClosed: state.isClosed,
                channels: Set(state.channelSubscribers.keys),
                patterns: Set(state.patternSubscribers.keys),
                connection: state.connection,
                wireChannels: state.wireChannels,
                wirePatterns: state.wirePatterns
            )
        }
    }

    private static func subscribeCommand(_ channels: Set<String>) -> RedisCommand {
        RedisCommand(arguments: [Array("SUBSCRIBE".utf8)] + channels.map { Array($0.utf8) })
    }

    private static func unsubscribeCommand(_ channels: Set<String>) -> RedisCommand {
        RedisCommand(arguments: [Array("UNSUBSCRIBE".utf8)] + channels.map { Array($0.utf8) })
    }

    private static func psubscribeCommand(_ patterns: Set<String>) -> RedisCommand {
        RedisCommand(arguments: [Array("PSUBSCRIBE".utf8)] + patterns.map { Array($0.utf8) })
    }

    private static func punsubscribeCommand(_ patterns: Set<String>) -> RedisCommand {
        RedisCommand(arguments: [Array("PUNSUBSCRIBE".utf8)] + patterns.map { Array($0.utf8) })
    }
}
