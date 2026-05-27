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

struct RunnerOptions: Sendable {

    let path: String
    let configPath: String
    let target: TargetSelection
    let stampFile: StampFile
}

enum TargetSelection: Sendable, Equatable {

    case omitted
    case named(String)

    var resolvedName: String {
        switch self {
        case .omitted: return "default"
        case .named(let value): return value
        }
    }
}

enum StampFile: Sendable, Equatable {

    case omitted
    case provided(String)
}

enum RunnerOptionError: Error, Sendable, Equatable {

    case missingValue(String)
    case unknownArgument(String)
    case pathRequired
    case configRequired
}

extension RunnerOptions {

    static func parse(arguments: [String]) throws(RunnerOptionError) -> RunnerOptions {
        var path = PathParseState.waiting
        var config = PathParseState.waiting
        var target: TargetSelection = .omitted
        var stamp = StampFile.omitted

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--path":
                guard index + 1 < arguments.count else { throw RunnerOptionError.missingValue(argument) }
                path = .found(arguments[index + 1])
                index += 2
            case "--config":
                guard index + 1 < arguments.count else { throw RunnerOptionError.missingValue(argument) }
                config = .found(arguments[index + 1])
                index += 2
            case "--target":
                guard index + 1 < arguments.count else { throw RunnerOptionError.missingValue(argument) }
                target = .named(arguments[index + 1])
                index += 2
            case "--stamp-file":
                guard index + 1 < arguments.count else { throw RunnerOptionError.missingValue(argument) }
                stamp = .provided(arguments[index + 1])
                index += 2
            default:
                throw RunnerOptionError.unknownArgument(argument)
            }
        }

        let resolvedPath: String
        switch path {
        case .waiting: throw RunnerOptionError.pathRequired
        case .found(let value): resolvedPath = value
        }

        let resolvedConfig: String
        switch config {
        case .waiting: throw RunnerOptionError.configRequired
        case .found(let value): resolvedConfig = value
        }

        return RunnerOptions(
            path: resolvedPath,
            configPath: resolvedConfig,
            target: target,
            stampFile: stamp
        )
    }
}

private enum PathParseState: Sendable {

    case waiting
    case found(String)
}
