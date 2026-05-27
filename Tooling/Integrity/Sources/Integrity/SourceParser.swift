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

public enum SourceParser {

    public static func loadFile(at path: String) throws(SourceParserError) -> SourceFile {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SourceParserError.cannotRead(path: path)
        }
        let contents = String(decoding: data, as: UTF8.self)
        return SourceFile(path: path, contents: contents)
    }

    public static func discoverSwiftFiles(
        at rootPath: String,
        excludingSubpaths excludedSubpaths: [String] = ["/.build/", "/.swiftpm/", "/Pods/", "/Carthage/"]
    ) throws(SourceParserError) -> [String] {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath)

        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: rootPath, isDirectory: &isDirectory)
        guard exists else { throw SourceParserError.pathDoesNotExist(path: rootPath) }

        if !isDirectory.boolValue {
            return rootPath.hasSuffix(".swift") ? [rootPath] : []
        }

        let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        guard let walker = enumerator else {
            throw SourceParserError.cannotEnumerate(path: rootPath)
        }

        var result: [String] = []
        for case let fileURL as URL in walker {
            let fsPath = fileURL.path
            if excludedSubpaths.contains(where: { fsPath.contains($0) }) {
                continue
            }
            if fsPath.hasSuffix(".swift") {
                result.append(fsPath)
            }
        }
        return result
    }
}

public enum SourceParserError: Error, Sendable, Equatable {

    case cannotRead(path: String)
    case pathDoesNotExist(path: String)
    case cannotEnumerate(path: String)
}
