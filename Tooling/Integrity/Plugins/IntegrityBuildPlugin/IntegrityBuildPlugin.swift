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
import PackagePlugin

@main
struct IntegrityBuildPlugin: BuildToolPlugin {

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else {
            return []
        }

        let tool = try context.tool(named: "IntegrityRunner")
        let packageRoot = context.package.directoryURL
        let configURL = packageRoot.appendingPathComponent("integrity.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return []
        }

        let stampFile = context.pluginWorkDirectoryURL.appendingPathComponent("Integrity-\(target.name).stamp")
        let inputFiles = sourceTarget.sourceFiles.map(\.url) + [configURL]

        return [
            .buildCommand(
                displayName: "Integrity check for \(target.name)",
                executable: tool.url,
                arguments: [
                    "--path", target.directoryURL.path,
                    "--config", configURL.path,
                    "--target", target.name,
                    "--stamp-file", stampFile.path,
                ],
                inputFiles: inputFiles,
                outputFiles: [stampFile]
            )
        ]
    }
}
