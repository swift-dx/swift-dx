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

import Foundation
import DXJetStream

enum NatsTestEnvironment {

    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["NATS_TEST_HOST"] != nil
    }

    static var endpoint: NatsEndpoint {
        let host = ProcessInfo.processInfo.environment["NATS_TEST_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["NATS_TEST_PORT"] ?? "") ?? 4222
        return NatsEndpoint(host: host, port: port)
    }

    static func uniqueSuffix() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt32.random(in: .min ... .max, using: &generator)
        var hex = String(value, radix: 16)
        while hex.count < 8 {
            hex = "0" + hex
        }
        return hex.uppercased()
    }

    static func uniqueStreamName(_ tag: String) throws -> StreamName {
        try StreamName("SWIFTDXIT_\(tag.uppercased())_\(uniqueSuffix())")
    }

    static func uniqueConsumerName(_ tag: String) throws -> ConsumerName {
        try ConsumerName("swiftdxit_\(tag.lowercased())_\(uniqueSuffix().lowercased())")
    }

    static func uniqueSubject(_ tag: String) throws -> Subject {
        try Subject("swift-dxit.\(tag.lowercased()).\(uniqueSuffix().lowercased())")
    }

}
