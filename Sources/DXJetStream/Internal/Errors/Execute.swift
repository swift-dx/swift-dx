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

@inline(__always)
func execute<Result>(_ body: () async throws -> Result) async throws(JetStreamError) -> Result {
    do {
        return try await body()
    } catch let typed as JetStreamError {
        throw typed
    } catch {
        throw .transportError(reason: "\(error)")
    }
}

@inline(__always)
func execute<Result>(_ body: () throws -> Result) throws(JetStreamError) -> Result {
    do {
        return try body()
    } catch let typed as JetStreamError {
        throw typed
    } catch {
        throw .transportError(reason: "\(error)")
    }
}
