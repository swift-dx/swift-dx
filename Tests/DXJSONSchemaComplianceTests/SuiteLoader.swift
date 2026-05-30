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
import DXCore
import DXJSONSchema

enum SuiteLoader {

    static func mainlineFiles() -> [SuiteFile] {
        loadDirectory("suite/draft2020-12")
    }

    static func remoteResources() -> [SchemaResource] {
        JSONSchema.draft2020MetaSchemaResources + suiteRemotes()
    }

    static func suiteRemotes() -> [SchemaResource] {
        guard let resourcePath = Bundle.module.resourcePath else { return [] }
        return loadRemotes(resourcePath + "/suite/remotes/draft2020-12", base: "http://localhost:1234/draft2020-12/")
    }

    static func loadRemotes(_ directory: String, base: String) -> [SchemaResource] {
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: directory)) ?? []
        var resources: [SchemaResource] = []
        for name in names where name.hasSuffix(".json") {
            appendResource(directory + "/" + name, uri: base + name, into: &resources)
        }
        return resources
    }

    static func appendResource(_ path: String, uri: String, into resources: inout [SchemaResource]) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        resources.append(SchemaResource(uri: uri, json: Array(data)))
    }

    static func loadDirectory(_ subdirectory: String) -> [SuiteFile] {
        guard let resourcePath = Bundle.module.resourcePath else { return [] }
        return loadFromPath(resourcePath + "/" + subdirectory)
    }

    static func loadFromPath(_ directory: String) -> [SuiteFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var files: [SuiteFile] = []
        for name in names where name.hasSuffix(".json") {
            appendFile(directory + "/" + name, named: name, into: &files)
        }
        return files
    }

    static func appendFile(_ path: String, named name: String, into files: inout [SuiteFile]) {
        guard case .found(let groups) = parseGroups(path) else { return }
        files.append(SuiteFile(name: name, groups: groups))
    }

    static func parseGroups(_ path: String) -> Lookup<[JSONValue]> {
        guard let data = FileManager.default.contents(atPath: path) else { return .notFound }
        return groupsFromData(data)
    }

    static func groupsFromData(_ data: Data) -> Lookup<[JSONValue]> {
        guard let value = try? JSONParser.parse(Array(data)) else { return .notFound }
        return arrayElements(value)
    }

    static func arrayElements(_ value: JSONValue) -> Lookup<[JSONValue]> {
        guard case .array(let groups) = value else { return .notFound }
        return .found(groups)
    }
}
