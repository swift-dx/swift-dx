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

import Testing
import Glibc
@testable import DXPostgres

@Suite struct PostgresListenerDeliveryTests {

    @Test(.timeLimit(.minutes(1)))
    func deliversABufferedNotificationThroughTheStream() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        let response = readyForQuery + notification(processID: 7, channel: "ch", payload: "hello")
        response.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        let listener = try PostgresListener(connection: connection, channels: ["ch"])

        var received = PostgresNotification(processID: 0, channel: "", payload: "")
        for try await note in listener.notifications {
            received = note
            break
        }
        #expect(received.processID == 7)
        #expect(received.channel == "ch")
        #expect(received.payload == "hello")
    }

    @Test(.timeLimit(.minutes(1)))
    func aFixedConnectionDropFinishesTheStreamWithAnError() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)

        readyForQuery.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        let listener = try PostgresListener(connection: connection, channels: ["ch"])

        close(descriptors[1])

        var caught = false
        do {
            for try await _ in listener.notifications {}
        } catch {
            caught = true
        }
        #expect(caught)
    }

    @Test(.timeLimit(.minutes(1)))
    func aReconnectableSubscriptionStandsByAndClosesAfterItsConnectionDrops() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)

        readyForQuery.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        let target = PostgresConnectionTarget(host: "127.0.0.1", port: 1, username: "x", password: "", database: "x", applicationName: "dx-test")
        let listener = try PostgresListener(connection: connection, source: .reconnectable(target), channels: ["ch"], permit: .unlimited())

        close(descriptors[1])
        try await Task.sleep(nanoseconds: 200_000_000)
        listener.close()

        for try await _ in listener.notifications {}
    }

    @Test(.timeLimit(.minutes(1)))
    func closeFinishesTheStreamWithoutError() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }

        readyForQuery.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }

        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        let listener = try PostgresListener(connection: connection, channels: ["ch"])
        listener.close()

        var count = 0
        for try await _ in listener.notifications {
            count += 1
        }
        #expect(count == 0)
    }

    private var readyForQuery: [UInt8] {
        [0x5A, 0x00, 0x00, 0x00, 0x05, 0x49]
    }

    private func notification(processID: Int32, channel: String, payload: String) -> [UInt8] {
        let body = bigEndianInt32(processID) + cString(channel) + cString(payload)
        return [0x41] + bigEndianInt32(Int32(body.count + 4)) + body
    }

    private func cString(_ value: String) -> [UInt8] {
        Array(value.utf8) + [0]
    }

    private func bigEndianInt32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }
}
