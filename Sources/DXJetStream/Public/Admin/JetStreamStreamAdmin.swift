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

public protocol JetStreamStreamAdmin: Sendable {
    func ensure(_ stream: StreamName, subject: Subject, storage: StorageMode) async throws(JetStreamError)
    func delete(_ stream: StreamName) async throws(JetStreamError)
}

extension JetStreamStreamAdmin {

    public func ensure(_ stream: StreamName, subject: Subject) async throws(JetStreamError) {
        try await ensure(stream, subject: subject, storage: .file)
    }
}
