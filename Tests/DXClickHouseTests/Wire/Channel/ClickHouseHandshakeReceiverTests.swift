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

@testable import DXClickHouse
import Foundation
import NIOCore
import NIOEmbedded
import Testing

@Suite("ClickHouse handshake receiver")
struct ClickHouseHandshakeReceiverTests {

    @Test("runHandshakeWithDeadline returns metadata when the handshake completes within the window (no false-trigger)")
    func handshakeDeadlineDoesNotFireWhenHandshakeSucceeds() async throws {
        // Set up a real EmbeddedChannel + receiver, then drive the
        // handshake-with-deadline against it while feeding a complete
        // server Hello. The deadline (500 ms) is well over the ~ms
        // it takes to feed bytes through an EmbeddedChannel, so the
        // body must win the race and metadata must come back without
        // the deadline ever firing.
        let channel = EmbeddedChannel()
        let receiver = ClickHouseHandshakeReceiver()
        try channel.pipeline.syncOperations.addHandler(receiver)

        let clientHello = ClickHouseClientHelloPacket(
            clientName: "SwiftDX Test",
            versionMajor: 1, versionMinor: 0, protocolRevision: 54_478,
            defaultDatabase: "obs", username: "u", password: ""
        )
        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse",
            versionMajor: 24, versionMinor: 8,
            serverRevision: 54_478,
            parallelReplicasProtocolVersion: .value(0),
            serverTimezone: .value("UTC"),
            displayName: .value("ch-test-1"),
            versionPatch: .value(0),
            chunkedProtocolSend: .value("notchunked"),
            chunkedProtocolRecv: .value("notchunked"),
            passwordComplexityRules: .value([]),
            interserverSecretNonce: .value(0),
            queryPlanSerializationVersion: .value(0)
        )
        var wire = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &wire)
        serverHello.encode(into: &wire, clientRevision: clientHello.protocolRevision)

        // Kick off the handshake and immediately deliver the bytes.
        async let handshakeResult = ClickHouseConnection.runHandshakeWithDeadline(
            clientHello: clientHello,
            receiver: receiver,
            deadline: .milliseconds(500)
        )
        try channel.writeInbound(wire)

        let metadata = try await handshakeResult
        #expect(metadata.negotiatedRevision == 54_478)
        #expect(metadata.serverDisplayName == "ch-test-1")
    }

    @Test("runHandshakeWithDeadline throws handshakeTimedOut when the receiver yields nothing")
    func handshakeDeadlineFiresOnSilentReceiver() async throws {
        // Construct a receiver that's never fed any bytes — simulates a
        // server that accepts TCP but never sends Hello (slow-loris,
        // half-open NAT, misbehaving proxy). The handshake-side
        // `for try await chunk in receiver.chunks` would suspend forever
        // without the deadline.
        let receiver = ClickHouseHandshakeReceiver()
        let clientHello = ClickHouseClientHelloPacket(
            clientName: "SwiftDX Test",
            versionMajor: 1, versionMinor: 0, protocolRevision: 54_478,
            defaultDatabase: "obs", username: "u", password: ""
        )

        let started = Date()
        var thrown: Error?
        do {
            _ = try await ClickHouseConnection.runHandshakeWithDeadline(
                clientHello: clientHello,
                receiver: receiver,
                deadline: .milliseconds(100)
            )
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)

        let received = try #require(thrown)
        guard case ClickHouseError.handshakeTimedOut(let nanos) = received else {
            Issue.record("expected handshakeTimedOut, got \(String(describing: thrown))")
            return
        }
        #expect(nanos == TimeAmount.milliseconds(100).nanoseconds)
        #expect(elapsed < 0.5, "deadline must fire near the configured 100 ms; observed \(elapsed)s")
    }

    @Test("inbound bytes are yielded onto the chunks stream")
    func inboundBytesYieldOntoStream() async throws {
        let receiver = ClickHouseHandshakeReceiver()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(receiver)

        var iterator = receiver.chunks.makeAsyncIterator()

        var first = ByteBuffer()
        first.writeBytes([UInt8(0x01), UInt8(0x02), UInt8(0x03)])
        try channel.writeInbound(first)

        let firstChunk = try #require(try await iterator.next())
        let bytes = firstChunk.getBytes(at: firstChunk.readerIndex, length: firstChunk.readableBytes) ?? []
        #expect(bytes == [0x01, 0x02, 0x03])
    }

    @Test("multiple inbound writes appear as separate chunks in order")
    func multipleWritesAppearAsSeparateChunks() async throws {
        let receiver = ClickHouseHandshakeReceiver()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(receiver)

        var iterator = receiver.chunks.makeAsyncIterator()

        var firstWrite = ByteBuffer()
        firstWrite.writeBytes([UInt8(0xAA)])
        try channel.writeInbound(firstWrite)

        var secondWrite = ByteBuffer()
        secondWrite.writeBytes([UInt8(0xBB), UInt8(0xCC)])
        try channel.writeInbound(secondWrite)

        let firstChunk = try #require(try await iterator.next())
        let secondChunk = try #require(try await iterator.next())
        #expect(firstChunk.getBytes(at: firstChunk.readerIndex, length: firstChunk.readableBytes) ?? [] == [0xAA])
        #expect(secondChunk.getBytes(at: secondChunk.readerIndex, length: secondChunk.readableBytes) ?? [] == [0xBB, 0xCC])
    }

    @Test("channel becoming inactive finishes the stream cleanly")
    func channelInactiveFinishesStream() async throws {
        let receiver = ClickHouseHandshakeReceiver()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(receiver)

        var firstWrite = ByteBuffer()
        firstWrite.writeBytes([UInt8(0x42)])
        try channel.writeInbound(firstWrite)

        var iterator = receiver.chunks.makeAsyncIterator()
        let first = try #require(try await iterator.next())
        let bytes = first.getBytes(at: first.readerIndex, length: first.readableBytes) ?? []
        #expect(bytes == [0x42])

        _ = try await channel.close()

        let next = try await iterator.next()
        #expect(next == nil)
    }

}
