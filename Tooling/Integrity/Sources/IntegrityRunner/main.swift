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
import Integrity

let arguments = Array(CommandLine.arguments.dropFirst())

let parsedOptions: RunnerOptions
do {
    parsedOptions = try RunnerOptions.parse(arguments: arguments)
} catch {
    FileHandle.standardError.write(Data("Integrity: \(error)\n".utf8))
    FileHandle.standardError.write(Data(
        "Usage: IntegrityRunner --path <path> --config <integrity.json> [--target <name>] [--stamp-file <path>]\n".utf8
    ))
    exit(RunnerExitCode.invalidArguments.rawValue)
}

let config: IntegrityConfig
do {
    config = try IntegrityConfig.loadFromFile(at: parsedOptions.configPath)
} catch {
    FileHandle.standardError.write(Data("Integrity: failed to load config at \(parsedOptions.configPath): \(error)\n".utf8))
    exit(RunnerExitCode.invalidConfig.rawValue)
}

let targetRules = config.rules(forTarget: parsedOptions.target.resolvedName)
if targetRules.isEmpty {
    FileHandle.standardError.write(Data(
        "Integrity: no rules resolved for target '\(parsedOptions.target.resolvedName)'.\n".utf8
    ))
}

let engine = RuleEngine(rules: targetRules, exemptions: config.exemptions)
let result: EngineResult
do {
    result = try engine.run(against: parsedOptions.path)
} catch {
    FileHandle.standardError.write(Data("Integrity: scan failed: \(error)\n".utf8))
    exit(RunnerExitCode.ioFailure.rawValue)
}

ConsoleReporter().report(result)

switch parsedOptions.stampFile {
case .omitted:
    break
case .provided(let stampPath):
    let stampURL = URL(fileURLWithPath: stampPath)
    do {
        try Data().write(to: stampURL)
    } catch {
        FileHandle.standardError.write(Data("Integrity: failed to write stamp: \(error)\n".utf8))
    }
}

exit(result.hasErrors ? RunnerExitCode.violations.rawValue : RunnerExitCode.ok.rawValue)
