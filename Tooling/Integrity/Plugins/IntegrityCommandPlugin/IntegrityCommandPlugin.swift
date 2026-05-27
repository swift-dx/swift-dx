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
struct IntegrityCommandPlugin: CommandPlugin {

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "IntegrityRunner")
        let packageRoot = context.package.directoryURL
        let configURL = packageRoot.appendingPathComponent("integrity.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw IntegrityPluginError.configMissing(path: configURL.path)
        }

        let process = Process()
        process.executableURL = tool.url
        process.currentDirectoryURL = packageRoot
        process.arguments = arguments.isEmpty
            ? ["--path", packageRoot.path, "--config", configURL.path, "--target", "default"]
            : arguments

        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw IntegrityPluginError.toolFailed(exitCode: Int(process.terminationStatus))
        }
    }
}
