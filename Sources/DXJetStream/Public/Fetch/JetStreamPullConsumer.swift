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

import DXCore
import Tracing

public protocol JetStreamPullConsumer: Sendable {
    func fetch(from stream: StreamName, for consumer: ConsumerName, needsPayload: Bool) async throws(JetStreamError) -> FetchStream
    func close(_ stream: FetchStream) async
    func messages(from stream: StreamName, for consumer: ConsumerName, options: PullOptions) -> AsyncThrowingStream<NatsMessage, any Error>
    func ack(_ message: NatsMessage)
    func acknowledge(replies: [[UInt8]])
}

extension JetStreamPullConsumer {

    public func messages(from stream: StreamName, for consumer: ConsumerName) -> AsyncThrowingStream<NatsMessage, any Error> {
        messages(from: stream, for: consumer, options: PullOptions())
    }

    public func messages(from stream: StreamName, for consumer: ConsumerName, handler: any DXMessageHandler<NatsMessage, JetStreamError>) -> SubscriptionHandle {
        messages(from: stream, for: consumer, options: PullOptions(), handler: handler)
    }

    public func messages(from stream: StreamName, for consumer: ConsumerName, options: PullOptions, handler: any DXMessageHandler<NatsMessage, JetStreamError>) -> SubscriptionHandle {
        let messageStream = messages(from: stream, for: consumer, options: options)
        let task = Task {
            do {
                for try await message in messageStream {
                    let extracted = TracePropagation.extract(message.headers)
                    await ServiceContext.$current.withValue(extracted) {
                        await handler.receive(message)
                    }
                }
            } catch let typed as JetStreamError {
                await handler.receive(error: typed)
            } catch {
                await handler.receive(error: .transportError(reason: "\(error)"))
            }
        }
        return SubscriptionHandle(cancellation: { task.cancel() })
    }
}
