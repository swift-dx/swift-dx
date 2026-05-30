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

import NIOCore

// First packet the server sends in response to ClickHouseClientHelloPacket.
// Wire layout (revision-gated fields). Each field is gated on the
// revision the *client* advertised: the server emits a field iff the
// client said it can read it. Negotiated revision = min(client, server).
//
//   String   server_name
//   UVarInt  version_major
//   UVarInt  version_minor
//   UVarInt  server_revision
//   UVarInt  parallel_replicas_protocol_version  (client_rev >= 54471)
//   String   server_timezone                     (client_rev >= 54058)
//   String   display_name                        (client_rev >= 54372)
//   UVarInt  version_patch                       (client_rev >= 54401)
//   String   chunked_protocol_send               (client_rev >= 54470)
//   String   chunked_protocol_recv               (client_rev >= 54470)
//   UVarInt  password_complexity_rules_count     (client_rev >= 54461)
//   { String pattern, String message } *count
//   8 bytes  interserver_secret_v2_nonce         (client_rev >= 54462)
//   ...      server_settings (empty terminator)  (client_rev >= 54474)
//   UVarInt  query_plan_serialization_version    (client_rev >= 54477)
//   UVarInt  cluster_processing_protocol_version (client_rev >= 54479)
//
// Decoder takes `clientRevision` (what we advertised) so it can gate
// reads correctly: the server emits based on what we said we support.
struct ClickHouseServerHelloPacket: Sendable, Equatable {

    static let revisionWithTimezone: UInt64 = 54_058
    static let revisionWithDisplayName: UInt64 = 54_372
    static let revisionWithVersionPatch: UInt64 = 54_401
    static let revisionWithPasswordComplexityRules: UInt64 = 54_461
    static let revisionWithInterserverSecretV2: UInt64 = 54_462
    static let revisionWithChunkedPackets: UInt64 = 54_470
    static let revisionWithVersionedParallelReplicas: UInt64 = 54_471
    static let revisionWithServerSettings: UInt64 = 54_474
    static let revisionWithQueryPlanSerialization: UInt64 = 54_477
    static let revisionWithVersionedClusterFunctionProtocol: UInt64 = 54_479

    let serverName: String
    let versionMajor: UInt64
    let versionMinor: UInt64
    let serverRevision: UInt64
    let parallelReplicasProtocolVersion: RevisionGated<UInt64>
    let serverTimezone: RevisionGated<String>
    let displayName: RevisionGated<String>
    let versionPatch: RevisionGated<UInt64>
    let chunkedProtocolSend: RevisionGated<String>
    let chunkedProtocolRecv: RevisionGated<String>
    let passwordComplexityRules: RevisionGated<[PasswordComplexityRule]>
    let interserverSecretNonce: RevisionGated<UInt64>
    let queryPlanSerializationVersion: RevisionGated<UInt64>
    let clusterProcessingProtocolVersion: RevisionGated<UInt64>

    struct PasswordComplexityRule: Sendable, Equatable {

        let pattern: String
        let message: String

        init(pattern: String, message: String) {
            self.pattern = pattern
            self.message = message
        }

    }

    init(
        serverName: String,
        versionMajor: UInt64,
        versionMinor: UInt64,
        serverRevision: UInt64,
        parallelReplicasProtocolVersion: RevisionGated<UInt64> = .unsupported,
        serverTimezone: RevisionGated<String> = .unsupported,
        displayName: RevisionGated<String> = .unsupported,
        versionPatch: RevisionGated<UInt64> = .unsupported,
        chunkedProtocolSend: RevisionGated<String> = .unsupported,
        chunkedProtocolRecv: RevisionGated<String> = .unsupported,
        passwordComplexityRules: RevisionGated<[PasswordComplexityRule]> = .unsupported,
        interserverSecretNonce: RevisionGated<UInt64> = .unsupported,
        queryPlanSerializationVersion: RevisionGated<UInt64> = .unsupported,
        clusterProcessingProtocolVersion: RevisionGated<UInt64> = .unsupported
    ) {
        self.serverName = serverName
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.serverRevision = serverRevision
        self.parallelReplicasProtocolVersion = parallelReplicasProtocolVersion
        self.serverTimezone = serverTimezone
        self.displayName = displayName
        self.versionPatch = versionPatch
        self.chunkedProtocolSend = chunkedProtocolSend
        self.chunkedProtocolRecv = chunkedProtocolRecv
        self.passwordComplexityRules = passwordComplexityRules
        self.interserverSecretNonce = interserverSecretNonce
        self.queryPlanSerializationVersion = queryPlanSerializationVersion
        self.clusterProcessingProtocolVersion = clusterProcessingProtocolVersion
    }

    func encode(into buffer: inout ByteBuffer, clientRevision: UInt64) {
        encodeServerIdentity(into: &buffer)
        // CH wire convention: every conditional field is gated on
        // `min(clientRevision, serverRevision)`. A real server emits a
        // field iff BOTH sides understand it; mirroring this keeps
        // test fixtures aligned and encode/decode symmetric.
        let effective = min(clientRevision, serverRevision)
        encodeGatedSimpleFields(into: &buffer, effective: effective)
        encodeGatedChunkedAndRules(into: &buffer, effective: effective)
        encodeGatedInterserverAndSettings(into: &buffer, effective: effective)
        encodeGatedProtocolVersions(into: &buffer, effective: effective)
    }

    private func encodeServerIdentity(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseString(serverName)
        buffer.writeClickHouseUVarInt(versionMajor)
        buffer.writeClickHouseUVarInt(versionMinor)
        buffer.writeClickHouseUVarInt(serverRevision)
    }

    private func encodeGatedSimpleFields(into buffer: inout ByteBuffer, effective: UInt64) {
        if effective >= Self.revisionWithVersionedParallelReplicas {
            buffer.writeClickHouseUVarInt(parallelReplicasProtocolVersion.unwrapOrDefault(0))
        }
        encodeGatedTimezoneAndDisplayName(into: &buffer, effective: effective)
    }

    private func encodeGatedTimezoneAndDisplayName(into buffer: inout ByteBuffer, effective: UInt64) {
        if effective >= Self.revisionWithTimezone {
            buffer.writeClickHouseString(serverTimezone.unwrapOrDefault("UTC"))
        }
        if effective >= Self.revisionWithDisplayName {
            buffer.writeClickHouseString(displayName.unwrapOrDefault(""))
        }
    }

    private func encodeGatedChunkedAndRules(into buffer: inout ByteBuffer, effective: UInt64) {
        if effective >= Self.revisionWithVersionPatch {
            buffer.writeClickHouseUVarInt(versionPatch.unwrapOrDefault(0))
        }
        if effective >= Self.revisionWithChunkedPackets {
            buffer.writeClickHouseString(chunkedProtocolSend.unwrapOrDefault("notchunked"))
            buffer.writeClickHouseString(chunkedProtocolRecv.unwrapOrDefault("notchunked"))
        }
        encodePasswordRules(into: &buffer, effective: effective)
    }

    private func encodePasswordRules(into buffer: inout ByteBuffer, effective: UInt64) {
        guard effective >= Self.revisionWithPasswordComplexityRules else { return }
        let rules = passwordComplexityRules.unwrapOrDefault([])
        buffer.writeClickHouseUVarInt(UInt64(rules.count))
        for rule in rules {
            buffer.writeClickHouseString(rule.pattern)
            buffer.writeClickHouseString(rule.message)
        }
    }

    private func encodeGatedInterserverAndSettings(into buffer: inout ByteBuffer, effective: UInt64) {
        if effective >= Self.revisionWithInterserverSecretV2 {
            buffer.writeInteger(interserverSecretNonce.unwrapOrDefault(0), endianness: .little)
        }
        if effective >= Self.revisionWithServerSettings {
            buffer.writeClickHouseUVarInt(0)
        }
    }

    private func encodeGatedProtocolVersions(into buffer: inout ByteBuffer, effective: UInt64) {
        if effective >= Self.revisionWithQueryPlanSerialization {
            buffer.writeClickHouseUVarInt(queryPlanSerializationVersion.unwrapOrDefault(0))
        }
        if effective >= Self.revisionWithVersionedClusterFunctionProtocol {
            buffer.writeClickHouseUVarInt(clusterProcessingProtocolVersion.unwrapOrDefault(0))
        }
    }

    static func decode(from buffer: inout ByteBuffer, clientRevision: UInt64) throws -> Self {
        let identity = try decodeServerIdentity(from: &buffer)
        let effective = min(clientRevision, identity.serverRevision)
        let simple = try decodeGatedSimpleFields(from: &buffer, effective: effective)
        let chunked = try decodeChunkedFields(from: &buffer, effective: effective)
        let rules = try decodePasswordRules(from: &buffer, effective: effective)
        let nonce = try decodeInterserverNonce(from: &buffer, effective: effective)
        try decodeServerSettings(from: &buffer, effective: effective)
        let trailing = try decodeProtocolVersions(from: &buffer, effective: effective)
        return .init(
            serverName: identity.serverName,
            versionMajor: identity.versionMajor,
            versionMinor: identity.versionMinor,
            serverRevision: identity.serverRevision,
            parallelReplicasProtocolVersion: simple.parallelReplicas,
            serverTimezone: simple.serverTimezone,
            displayName: simple.displayName,
            versionPatch: chunked.versionPatch,
            chunkedProtocolSend: chunked.send,
            chunkedProtocolRecv: chunked.recv,
            passwordComplexityRules: rules,
            interserverSecretNonce: nonce,
            queryPlanSerializationVersion: trailing.queryPlan,
            clusterProcessingProtocolVersion: trailing.cluster
        )
    }

    private struct ServerIdentity {
        let serverName: String
        let versionMajor: UInt64
        let versionMinor: UInt64
        let serverRevision: UInt64
    }

    private static func decodeServerIdentity(from buffer: inout ByteBuffer) throws -> ServerIdentity {
        let serverName = try buffer.readClickHouseString()
        let versionMajor = try buffer.readClickHouseUVarInt()
        let versionMinor = try buffer.readClickHouseUVarInt()
        let serverRevision = try buffer.readClickHouseUVarInt()
        return ServerIdentity(serverName: serverName, versionMajor: versionMajor, versionMinor: versionMinor, serverRevision: serverRevision)
    }

    private struct GatedSimpleFields {
        let parallelReplicas: RevisionGated<UInt64>
        let serverTimezone: RevisionGated<String>
        let displayName: RevisionGated<String>
    }

    private static func decodeGatedSimpleFields(from buffer: inout ByteBuffer, effective: UInt64) throws -> GatedSimpleFields {
        let parallelReplicas = try readGatedUVarInt(from: &buffer, effective: effective, threshold: Self.revisionWithVersionedParallelReplicas)
        let serverTimezone = try readGatedString(from: &buffer, effective: effective, threshold: Self.revisionWithTimezone)
        let displayName = try readGatedString(from: &buffer, effective: effective, threshold: Self.revisionWithDisplayName)
        return GatedSimpleFields(parallelReplicas: parallelReplicas, serverTimezone: serverTimezone, displayName: displayName)
    }

    private static func readGatedUVarInt(from buffer: inout ByteBuffer, effective: UInt64, threshold: UInt64) throws -> RevisionGated<UInt64> {
        guard effective >= threshold else { return .unsupported }
        return .value(try buffer.readClickHouseUVarInt())
    }

    private static func readGatedString(from buffer: inout ByteBuffer, effective: UInt64, threshold: UInt64) throws -> RevisionGated<String> {
        guard effective >= threshold else { return .unsupported }
        return .value(try buffer.readClickHouseString())
    }

    private struct ChunkedFields {
        let versionPatch: RevisionGated<UInt64>
        let send: RevisionGated<String>
        let recv: RevisionGated<String>
    }

    private static func decodeChunkedFields(from buffer: inout ByteBuffer, effective: UInt64) throws -> ChunkedFields {
        let versionPatch = try readGatedUVarInt(from: &buffer, effective: effective, threshold: Self.revisionWithVersionPatch)
        let (send, recv) = try decodeChunkedNames(from: &buffer, effective: effective)
        return ChunkedFields(versionPatch: versionPatch, send: send, recv: recv)
    }

    private static func decodeChunkedNames(from buffer: inout ByteBuffer, effective: UInt64) throws -> (RevisionGated<String>, RevisionGated<String>) {
        guard effective >= Self.revisionWithChunkedPackets else { return (.unsupported, .unsupported) }
        let send = try buffer.readClickHouseString()
        let recv = try buffer.readClickHouseString()
        return (.value(send), .value(recv))
    }

    private static func decodePasswordRules(from buffer: inout ByteBuffer, effective: UInt64) throws -> RevisionGated<[PasswordComplexityRule]> {
        guard effective >= Self.revisionWithPasswordComplexityRules else { return .unsupported }
        let countInt = try decodePasswordRulesCount(from: &buffer)
        return .value(try collectPasswordRules(count: countInt, from: &buffer))
    }

    private static func decodePasswordRulesCount(from buffer: inout ByteBuffer) throws -> Int {
        let count = try buffer.readClickHouseUVarInt()
        guard let countInt = Int(exactly: count) else {
            throw ClickHouseError.blockRowCountExceedsInt(count)
        }
        return countInt
    }

    private static func collectPasswordRules(count: Int, from buffer: inout ByteBuffer) throws -> [PasswordComplexityRule] {
        var collected: [PasswordComplexityRule] = []
        collected.reserveCapacity(min(count, buffer.readableBytes))
        for _ in 0..<count {
            collected.append(try decodePasswordRule(from: &buffer))
        }
        return collected
    }

    private static func decodePasswordRule(from buffer: inout ByteBuffer) throws -> PasswordComplexityRule {
        let pattern = try buffer.readClickHouseString()
        let message = try buffer.readClickHouseString()
        return PasswordComplexityRule(pattern: pattern, message: message)
    }

    private static func decodeInterserverNonce(from buffer: inout ByteBuffer, effective: UInt64) throws -> RevisionGated<UInt64> {
        guard effective >= Self.revisionWithInterserverSecretV2 else { return .unsupported }
        guard let value: UInt64 = buffer.readInteger(endianness: .little) else {
            throw ClickHouseError.truncatedBuffer(needed: 8, available: buffer.readableBytes)
        }
        return .value(value)
    }

    private static func decodeServerSettings(from buffer: inout ByteBuffer, effective: UInt64) throws {
        guard effective >= Self.revisionWithServerSettings else { return }
        try Self.skipServerSettings(from: &buffer)
    }

    private struct TrailingProtocolVersions {
        let queryPlan: RevisionGated<UInt64>
        let cluster: RevisionGated<UInt64>
    }

    private static func decodeProtocolVersions(from buffer: inout ByteBuffer, effective: UInt64) throws -> TrailingProtocolVersions {
        let queryPlan = try readGatedUVarInt(from: &buffer, effective: effective, threshold: Self.revisionWithQueryPlanSerialization)
        let cluster = try readGatedUVarInt(from: &buffer, effective: effective, threshold: Self.revisionWithVersionedClusterFunctionProtocol)
        return TrailingProtocolVersions(queryPlan: queryPlan, cluster: cluster)
    }

    private static func skipServerSettings(from buffer: inout ByteBuffer) throws {
        while true {
            let name = try buffer.readClickHouseString()
            if name.isEmpty { return }
            // Setting in STRINGS_WITH_FLAGS format: name, flags (UVarInt),
            // value (string). Skip flags + value.
            _ = try buffer.readClickHouseUVarInt()
            _ = try buffer.readClickHouseString()
        }
    }

}
