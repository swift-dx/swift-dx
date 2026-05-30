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

import Atomics

extension SchemaRegistry {

    public func verify<ID: Sendable>(batch requests: [VerificationRequest<ID>]) async -> VerificationReport<ID> {
        let snapshot = current.load(ordering: .acquiring)
        return await runVerification(requests, snapshot)
    }

    func runVerification<ID: Sendable>(_ requests: [VerificationRequest<ID>], _ snapshot: RegistrySnapshot) async -> VerificationReport<ID> {
        let bounds = chunkBounds(requests.count)
        return await withTaskGroup(of: VerifyChunk<ID>.self) { group in
            for bound in bounds {
                group.addTask { verifyRange(requests, bound, snapshot) }
            }
            var chunks: [VerifyChunk<ID>] = []
            for await chunk in group {
                chunks.append(chunk)
            }
            return assembleReport(chunks)
        }
    }

    func chunkBounds(_ count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        return chunkRanges(count, chunkSize(count))
    }

    func chunkSize(_ count: Int) -> Int {
        Swift.max(256, (count + 4095) / 4096)
    }

    func chunkRanges(_ count: Int, _ size: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            ranges.append(start ..< Swift.min(start + size, count))
            start += size
        }
        return ranges
    }
}

func assembleReport<ID: Sendable>(_ chunks: [VerifyChunk<ID>]) -> VerificationReport<ID> {
    var succeeded: [ID] = []
    var failed: [FailedVerification<ID>] = []
    for chunk in chunks.sorted(by: { $0.start < $1.start }) {
        succeeded.append(contentsOf: chunk.succeeded)
        failed.append(contentsOf: chunk.failed)
    }
    return VerificationReport(succeeded: succeeded, failed: failed)
}

func verifyRange<ID: Sendable>(_ requests: [VerificationRequest<ID>], _ range: Range<Int>, _ snapshot: RegistrySnapshot) -> VerifyChunk<ID> {
    var succeeded: [ID] = []
    var failed: [FailedVerification<ID>] = []
    for index in range {
        classify(requests[index], snapshot, &succeeded, &failed)
    }
    return VerifyChunk(start: range.lowerBound, succeeded: succeeded, failed: failed)
}

func classify<ID: Sendable>(_ request: VerificationRequest<ID>, _ snapshot: RegistrySnapshot, _ succeeded: inout [ID], _ failed: inout [FailedVerification<ID>]) {
    let result = SchemaRegistry.validate(request.payload, against: snapshot.schemas(for: request.type), type: request.type)
    guard result.isValid else { return failed.append(FailedVerification(id: request.id, result: result)) }
    succeeded.append(request.id)
}
