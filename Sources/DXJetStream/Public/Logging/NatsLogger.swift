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

import Logging

public struct NatsLogger: Sendable {

    let logger: Logger
    let isSilent: Bool

    public init(_ logger: Logger) {
        self.logger = logger
        self.isSilent = false
    }

    private init(silent: Logger) {
        self.logger = silent
        self.isSilent = true
    }

    public static let silent: NatsLogger = NatsLogger(silent: silentLogger())

    public static func standard(label: String = "swift-dx.jetstream") -> NatsLogger {
        NatsLogger(Logger(label: label))
    }

    @inline(__always)
    func emit(_ event: @autoclosure () -> NatsLogEvent, level: Logger.Level = .debug) {
        if isSilent { return }
        guard logger.logLevel <= level else { return }
        let resolved = event()
        let (message, metadata) = render(resolved)
        logger.log(level: level, "\(message)", metadata: metadata)
    }

    @inline(__always)
    func emitError(_ event: @autoclosure () -> NatsLogEvent) {
        if isSilent { return }
        guard logger.logLevel <= .error else { return }
        let resolved = event()
        let (message, metadata) = render(resolved)
        logger.error("\(message)", metadata: metadata)
    }

    private func render(_ event: NatsLogEvent) -> (Logger.Message, Logger.Metadata) {
        switch event {
        case .connecting(let endpoint):
            return ("connecting", ["host": "\(endpoint.host)", "port": "\(endpoint.port)"])
        case .connected(let endpoint):
            return ("connected", ["host": "\(endpoint.host)", "port": "\(endpoint.port)"])
        case .disconnected:
            return ("disconnected", [:])
        case .handshakeReceivedInfo:
            return ("handshake.info_received", [:])
        case .handshakeAuthenticatedSent:
            return ("handshake.authenticated_connect_sent", [:])
        case .handshakeAnonymousSent:
            return ("handshake.anonymous_connect_sent", [:])
        case .handshakeCompleted:
            return ("handshake.completed", [:])
        case .handshakeFailed(let reason):
            return ("handshake.failed", ["reason": "\(reason)"])
        case .publishStarted(let traceId, let subject, let count):
            return ("publish.batch_started", ["trace": "\(traceId)", "subject": "\(subject)", "count": "\(count)"])
        case .publishAcked(let traceId):
            return ("publish.batch_acked", ["trace": "\(traceId)"])
        case .fetchOpened(let stream, let consumer):
            return ("fetch.opened", ["stream": "\(stream)", "consumer": "\(consumer)"])
        case .fetchRequestSent(let traceId, let batch):
            return ("fetch.request_sent", ["trace": "\(traceId)", "batch": "\(batch)"])
        case .fetchResultReceived(let traceId, let replies):
            return ("fetch.result_received", ["trace": "\(traceId)", "replies": "\(replies)"])
        case .fetchStatus(let traceId, let code):
            return ("fetch.status", ["trace": "\(traceId)", "code": "\(code)"])
        case .fetchClosed:
            return ("fetch.closed", [:])
        case .streamEnsured(let name):
            return ("stream.ensured", ["name": "\(name)"])
        case .streamDeleted(let name):
            return ("stream.deleted", ["name": "\(name)"])
        case .consumerEnsured(let stream, let consumer):
            return ("consumer.ensured", ["stream": "\(stream)", "consumer": "\(consumer)"])
        case .errorRaised(let reason):
            return ("error", ["reason": "\(reason)"])
        }
    }
}

private func silentLogger() -> Logger {
    Logger(label: "swift-dx.jetstream.silent", factory: { _ in SilentLogHandler() })
}

private struct SilentLogHandler: LogHandler {

    var logLevel: Logger.Level = .critical
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { nil }
        set { _ = newValue }
    }

    func log(event: LogEvent) {
    }
}
