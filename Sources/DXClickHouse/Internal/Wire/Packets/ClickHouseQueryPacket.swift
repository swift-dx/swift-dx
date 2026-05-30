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

// Carries one SELECT/INSERT/CREATE/etc. statement to the server.
// Wire layout (revision-gated):
//   String   queryID
//   ClientInfo (per its own encode)
//   Settings list — empty terminator (single zero byte)
//   String   interserverSecret  (>= 54441)
//   UVarInt  queryProcessingStage  (typically .complete = 2)
//   UVarInt  compression  (0 = off, 1 = on)
//   String   queryText
//   Parameters list, empty terminator  (>= 54459)
//
// Settings, parameters, and trace-context emission are deferred (see
// ClickHouseClientInfo). The decoder asserts the wire matches our
// "always empty" expectation for those fields and throws otherwise.
struct ClickHouseQueryPacket: Sendable, Equatable {

    static let revisionWithInterserverSecret: UInt64 = 54_441
    static let revisionWithInterserverExternallyGrantedRoles: UInt64 = 54_472
    static let revisionWithQueryParameters: UInt64 = 54_459

    static let settingFlagImportant: UInt64 = 0x01
    static let settingFlagCustom: UInt64 = 0x02
    static let settingFlagObsolete: UInt64 = 0x04

    enum QueryProcessingStage: UInt64, Sendable, Equatable {

        case fetchColumns = 0
        case withMergeableState = 1
        case complete = 2
        case withMergeableStateAfterAggregation = 3
        case withMergeableStateAfterAggregationAndLimit = 4

    }

    let queryID: String
    var clientInfo: ClickHouseClientInfo = .init()
    var settings: [ClickHouseQuerySetting] = []
    var interserverSecret: String = ""
    var queryProcessingStage: QueryProcessingStage = .complete
    var compression: Bool = false
    let queryText: String
    var parameters: [ClickHouseQueryParameter] = []

    func encode(into buffer: inout ByteBuffer, revision: UInt64) throws {
        buffer.writeClickHouseString(queryID)
        clientInfo.encode(into: &buffer, revision: revision)
        try encodeSettingsBlock(into: &buffer)
        encodeInterserverSection(into: &buffer, revision: revision)
        encodeStageAndQuery(into: &buffer)
        try encodeParametersBlock(into: &buffer, revision: revision)
    }

    private func encodeSettingsBlock(into buffer: inout ByteBuffer) throws {
        for setting in settings {
            try Self.encodeSetting(setting, into: &buffer)
        }
        buffer.writeClickHouseString("")
    }

    private func encodeInterserverSection(into buffer: inout ByteBuffer, revision: UInt64) {
        if revision >= Self.revisionWithInterserverExternallyGrantedRoles {
            buffer.writeClickHouseString("")
        }
        if revision >= Self.revisionWithInterserverSecret {
            buffer.writeClickHouseString(interserverSecret)
        }
    }

    private func encodeStageAndQuery(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseUVarInt(queryProcessingStage.rawValue)
        buffer.writeClickHouseUVarInt(compression ? 1 : 0)
        buffer.writeClickHouseString(queryText)
    }

    private func encodeParametersBlock(into buffer: inout ByteBuffer, revision: UInt64) throws {
        guard revision >= Self.revisionWithQueryParameters else { return }
        for parameter in parameters {
            try Self.encodeParameter(parameter, into: &buffer)
        }
        buffer.writeClickHouseString("")
    }

    private static func encodeParameter(_ parameter: ClickHouseQueryParameter, into buffer: inout ByteBuffer) throws {
        guard !parameter.name.isEmpty else {
            throw ClickHouseError.emptyQueryParameterName
        }
        buffer.writeClickHouseString(parameter.name)
        buffer.writeClickHouseUVarInt(settingFlagCustom)
        buffer.writeClickHouseString(parameter.value)
    }

    private static func encodeSetting(_ setting: ClickHouseQuerySetting, into buffer: inout ByteBuffer) throws {
        guard !setting.name.isEmpty else {
            throw ClickHouseError.emptyQuerySettingName
        }
        buffer.writeClickHouseString(setting.name)
        buffer.writeClickHouseUVarInt(encodeSettingFlags(for: setting))
        buffer.writeClickHouseString(setting.value)
    }

    private static func encodeSettingFlags(for setting: ClickHouseQuerySetting) -> UInt64 {
        var flags: UInt64 = 0
        if setting.important { flags |= settingFlagImportant }
        flags |= encodeCustomAndObsoleteFlags(for: setting)
        return flags
    }

    private static func encodeCustomAndObsoleteFlags(for setting: ClickHouseQuerySetting) -> UInt64 {
        var flags: UInt64 = 0
        if setting.custom { flags |= settingFlagCustom }
        if setting.obsolete { flags |= settingFlagObsolete }
        return flags
    }

    static func decode(from buffer: inout ByteBuffer, revision: UInt64) throws -> Self {
        let queryID = try buffer.readClickHouseString()
        let clientInfo = try ClickHouseClientInfo.decode(from: &buffer, revision: revision)
        let settings = try decodeSettings(from: &buffer)
        try skipExternallyGrantedRoles(from: &buffer, revision: revision)
        let interserverSecret = try decodeInterserverSecret(from: &buffer, revision: revision)
        let stage = try decodeQueryProcessingStage(from: &buffer)
        let compressionRaw = try buffer.readClickHouseUVarInt()
        let queryText = try buffer.readClickHouseString()
        let parameters = try decodeQueryParameters(from: &buffer, revision: revision)
        return .init(
            queryID: queryID,
            clientInfo: clientInfo,
            settings: settings,
            interserverSecret: interserverSecret,
            queryProcessingStage: stage,
            compression: compressionRaw != 0,
            queryText: queryText,
            parameters: parameters
        )
    }

    private static func skipExternallyGrantedRoles(from buffer: inout ByteBuffer, revision: UInt64) throws {
        guard revision >= Self.revisionWithInterserverExternallyGrantedRoles else { return }
        _ = try buffer.readClickHouseString()
    }

    private static func decodeInterserverSecret(from buffer: inout ByteBuffer, revision: UInt64) throws -> String {
        guard revision >= Self.revisionWithInterserverSecret else { return "" }
        return try buffer.readClickHouseString()
    }

    private static func decodeQueryProcessingStage(from buffer: inout ByteBuffer) throws -> QueryProcessingStage {
        let stageRaw = try buffer.readClickHouseUVarInt()
        guard let stage = QueryProcessingStage(rawValue: stageRaw) else {
            throw ClickHouseError.unknownQueryProcessingStage(rawValue: stageRaw)
        }
        return stage
    }

    private static func decodeQueryParameters(from buffer: inout ByteBuffer, revision: UInt64) throws -> [ClickHouseQueryParameter] {
        guard revision >= Self.revisionWithQueryParameters else { return [] }
        return try decodeParameters(from: &buffer)
    }

    private static func decodeParameters(from buffer: inout ByteBuffer) throws -> [ClickHouseQueryParameter] {
        var parameters: [ClickHouseQueryParameter] = []
        while true {
            let name = try buffer.readClickHouseString()
            if name.isEmpty {
                return parameters
            }
            // Parameters reuse the Setting wire layout: skip the flags byte
            // (always Custom for params) and read the value.
            _ = try buffer.readClickHouseUVarInt()
            let value = try buffer.readClickHouseString()
            parameters.append(.init(name: name, value: value))
        }
    }

    private static func decodeSettings(from buffer: inout ByteBuffer) throws -> [ClickHouseQuerySetting] {
        var settings: [ClickHouseQuerySetting] = []
        while true {
            let name = try buffer.readClickHouseString()
            if name.isEmpty {
                return settings
            }
            let flags = try buffer.readClickHouseUVarInt()
            let value = try buffer.readClickHouseString()
            settings.append(.init(
                name: name,
                value: value,
                important: flags & settingFlagImportant != 0,
                custom: flags & settingFlagCustom != 0,
                obsolete: flags & settingFlagObsolete != 0
            ))
        }
    }

}
