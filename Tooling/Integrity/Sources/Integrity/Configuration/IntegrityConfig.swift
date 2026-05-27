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

public struct IntegrityConfig: Sendable {

    public let rulesByID: [String: any IntegrityRule]
    public let targets: [String: [String]]
    public let defaultRuleIDs: [String]
    public let exemptions: [Exemption]

    public init(
        rulesByID: [String: any IntegrityRule],
        targets: [String: [String]],
        defaultRuleIDs: [String],
        exemptions: [Exemption] = []
    ) {
        self.rulesByID = rulesByID
        self.targets = targets
        self.defaultRuleIDs = defaultRuleIDs
        self.exemptions = exemptions
    }

    public func rules(forTarget targetName: String) -> [any IntegrityRule] {
        let ruleIDs = targets[targetName] ?? defaultRuleIDs
        return ruleIDs.compactMap { rulesByID[$0] }
    }
}

public struct Exemption: Sendable, Equatable, Codable {

    public let path: String
    public let rules: [String]
    public let reason: String

    public init(path: String, rules: [String], reason: String) {
        self.path = path
        self.rules = rules
        self.reason = reason
    }

    public func covers(file: String, ruleID: String) -> Bool {
        guard rules.contains(ruleID) else { return false }
        if file == path { return true }
        return file.hasSuffix("/" + path)
    }
}

extension IntegrityConfig {

    public static func loadFromFile(at path: String) throws(ConfigError) -> IntegrityConfig {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.cannotRead(path: path)
        }
        return try load(from: data)
    }

    public static func load(from data: Data) throws(ConfigError) -> IntegrityConfig {
        let raw = try decodeRawConfig(from: data)
        let (defaultIDs, targets) = try resolveTargets(raw.targets)
        let rulesByID = try buildRules(for: defaultIDs, targets: targets)
        let exemptions = raw.exemptions
        return IntegrityConfig(rulesByID: rulesByID, targets: targets, defaultRuleIDs: defaultIDs, exemptions: exemptions)
    }

    private static func decodeRawConfig(from data: Data) throws(ConfigError) -> RawConfig {
        do {
            return try JSONDecoder().decode(RawConfig.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(reason: "\(error)")
        }
    }

    private static func resolveTargets(
        _ raw: [String: RawTargetValue]
    ) throws(ConfigError) -> (defaultIDs: [String], targets: [String: [String]]) {
        var defaultIDs: [String] = []
        var targets: [String: [String]] = [:]
        for (name, value) in raw {
            let ids = try resolveTargetIDs(name: name, value: value, raw: raw)
            if name == "default" {
                defaultIDs = ids
            } else {
                targets[name] = ids
            }
        }
        return (defaultIDs, targets)
    }

    private static func resolveTargetIDs(
        name: String,
        value: RawTargetValue,
        raw: [String: RawTargetValue]
    ) throws(ConfigError) -> [String] {
        switch value {
        case .list(let ids):
            return ids
        case .inherit(let parent):
            guard let parentIDs = raw[parent]?.listValue else {
                throw ConfigError.unknownTarget(parent: parent, referencedBy: name)
            }
            return parentIDs
        }
    }

    private static func buildRules(
        for defaultIDs: [String],
        targets: [String: [String]]
    ) throws(ConfigError) -> [String: any IntegrityRule] {
        var allIDs = Set<String>(defaultIDs)
        for ids in targets.values { allIDs.formUnion(ids) }
        var rulesByID: [String: any IntegrityRule] = [:]
        for id in allIDs {
            rulesByID[id] = try BuiltInRules.makeRule(id: id)
        }
        return rulesByID
    }
}

public enum ConfigError: Error, Sendable, Equatable {

    case cannotRead(path: String)
    case invalidJSON(reason: String)
    case unknownRuleID(String)
    case unknownTarget(parent: String, referencedBy: String)
}

struct RawConfig: Decodable, Sendable {

    let targets: [String: RawTargetValue]
    let exemptions: [Exemption]

    enum CodingKeys: String, CodingKey {

        case targets
        case exemptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targets = try container.decode([String: RawTargetValue].self, forKey: .targets)
        if container.contains(.exemptions) {
            self.exemptions = try container.decode([Exemption].self, forKey: .exemptions)
        } else {
            self.exemptions = []
        }
    }
}

enum RawTargetValue: Sendable {

    case list([String])
    case inherit(String)

    var listValue: [String]? {
        switch self {
        case .list(let value): return value
        case .inherit: return nil
        }
    }
}

extension RawTargetValue: Decodable {

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
            return
        }
        let parent = try container.decode(String.self)
        self = .inherit(parent)
    }
}
