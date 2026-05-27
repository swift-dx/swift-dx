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

public struct ConsumerConfiguration: Sendable, Equatable {

    public var ackWait: TimeSpan
    public var ackPolicy: AckPolicy
    public var maxAckPending: Int
    public var subjectFilter: SubjectMatch
    public var deliveryAttemptLimit: DeliveryAttemptLimit

    public init(ackWait: TimeSpan, ackPolicy: AckPolicy, maxAckPending: Int, subjectFilter: SubjectMatch, deliveryAttemptLimit: DeliveryAttemptLimit) {
        self.ackWait = ackWait
        self.ackPolicy = ackPolicy
        self.maxAckPending = maxAckPending
        self.subjectFilter = subjectFilter
        self.deliveryAttemptLimit = deliveryAttemptLimit
    }

    public static func standard() -> ConsumerConfiguration {
        ConsumerConfiguration(ackWait: .seconds(30), ackPolicy: .explicit, maxAckPending: 1_000, subjectFilter: .any, deliveryAttemptLimit: .unlimited)
    }
}
