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

import Testing
import DXJSONSchema

@Suite
struct SchemaRegistryBulkTests {

    static let intSchema = ##"{"type":"integer"}"##
    static let stringSchema = ##"{"type":"string"}"##
    static let malformed = ##"{"type":"##

    @Test
    func applyReplacesWholeSetAtomically() throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "old", schema: Self.intSchema)])
        let before = registry.generation

        try registry.apply([
            SchemaEnvelope(type: "a", schema: Self.intSchema),
            SchemaEnvelope(type: "b", schema: Self.stringSchema),
        ])

        #expect(Set(registry.registeredTypes) == ["a", "b"])
        #expect(registry.generation.value > before.value)
    }

    @Test
    func applyRollsBackWhenAnySchemaFails() throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "kept", schema: Self.intSchema)])
        let before = registry.generation

        #expect(throws: JSONSchemaError.self) {
            try registry.apply([
                SchemaEnvelope(type: "good", schema: Self.intSchema),
                SchemaEnvelope(type: "bad", schema: Self.malformed),
            ])
        }

        #expect(registry.registeredTypes == ["kept"])
        #expect(registry.generation.value == before.value)
        #expect(registry.validate("5", type: "kept").isValid)
    }

    @Test
    func applyEmptyClearsRegistry() throws {
        let registry = SchemaRegistry()
        try registry.apply([
            SchemaEnvelope(type: "a", schema: Self.intSchema),
            SchemaEnvelope(type: "b", schema: Self.stringSchema),
        ])
        let before = registry.generation

        try registry.apply([])

        #expect(registry.registeredTypes.isEmpty)
        #expect(registry.generation.value > before.value)
        #expect(Self.isNotRegistered(registry.validate("5", type: "a")))
    }

    @Test
    func mergeUpsertsTypeKeepingOthers() throws {
        let registry = SchemaRegistry()
        try registry.apply([
            SchemaEnvelope(type: "untouched", schema: Self.intSchema),
            SchemaEnvelope(type: "replaced", schema: Self.intSchema),
        ])

        try registry.merge([
            SchemaEnvelope(type: "replaced", schema: Self.stringSchema),
            SchemaEnvelope(type: "added", schema: Self.stringSchema),
        ])

        #expect(Set(registry.registeredTypes) == ["untouched", "replaced", "added"])
        #expect(registry.validate(##""x""##, type: "replaced").isValid)
        #expect(!registry.validate("5", type: "replaced").isValid)
        #expect(registry.validate("5", type: "untouched").isValid)
    }

    @Test
    func dropOldRevisionTightensType() throws {
        let registry = SchemaRegistry()
        try registry.apply([
            SchemaEnvelope(type: "T", schema: Self.intSchema),
            SchemaEnvelope(type: "T", schema: Self.stringSchema),
        ])
        #expect(registry.validate("5", type: "T").isValid)
        #expect(registry.validate(##""x""##, type: "T").isValid)

        try registry.apply([SchemaEnvelope(type: "T", schema: Self.stringSchema)])
        #expect(registry.revisionCount(ofType: "T") == 1)
        #expect(!registry.validate("5", type: "T").isValid)
        #expect(registry.validate(##""x""##, type: "T").isValid)
    }

    @Test
    func verifyBatchBucketsByIdentifierAndOutcome() async throws {
        let registry = SchemaRegistry()
        try registry.apply([
            SchemaEnvelope(type: "ints", schema: Self.intSchema),
            SchemaEnvelope(type: "strings", schema: Self.stringSchema),
        ])

        let report = await registry.verify(batch: [
            VerificationRequest(id: 1, type: "ints", payload: "7"),
            VerificationRequest(id: 2, type: "ints", payload: ##""nope""##),
            VerificationRequest(id: 3, type: "strings", payload: ##""ok""##),
            VerificationRequest(id: 4, type: "absent", payload: "1"),
        ])

        #expect(Set(report.succeeded) == [1, 3])
        #expect(Set(report.failed.map { $0.id }) == [2, 4])
        #expect(report.successCount + report.failureCount == 4)
        guard let unknown = report.failed.first(where: { $0.id == 4 }) else {
            Issue.record("missing failed id 4")
            return
        }
        #expect(Self.isNotRegistered(unknown.result))
    }

    @Test
    func verifyBatchOrsAcrossRevisions() async throws {
        let registry = SchemaRegistry()
        try registry.apply([
            SchemaEnvelope(type: "T", schema: Self.intSchema),
            SchemaEnvelope(type: "T", schema: Self.stringSchema),
        ])
        let report = await registry.verify(batch: [
            VerificationRequest(id: 1, type: "T", payload: "5"),
            VerificationRequest(id: 2, type: "T", payload: ##""s""##),
            VerificationRequest(id: 3, type: "T", payload: "true"),
        ])
        #expect(Set(report.succeeded) == [1, 2])
        #expect(report.failed.map { $0.id } == [3])
    }

    @Test
    func emptyBatchReturnsEmptyReport() async {
        let report = await SchemaRegistry().verify(batch: [VerificationRequest<Int>]())
        #expect(report.succeeded.isEmpty)
        #expect(report.failed.isEmpty)
    }

    @Test
    func verifyBatchFlagsMalformedPayload() async throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "ints", schema: Self.intSchema)])
        let report = await registry.verify(batch: [
            VerificationRequest(id: 1, type: "ints", payload: "5"),
            VerificationRequest(id: 2, type: "ints", payload: "{"),
        ])
        #expect(report.succeeded == [1])
        guard let bad = report.failed.first(where: { $0.id == 2 }) else {
            Issue.record("missing failed id 2")
            return
        }
        #expect(Self.isNotValidJSON(bad.result))
    }

    @Test
    func largeParallelBatchAccountsForEveryEntry() async throws {
        let registry = SchemaRegistry()
        try registry.apply([SchemaEnvelope(type: "ints", schema: Self.intSchema)])

        var requests: [VerificationRequest<Int>] = []
        for index in 0 ..< 50_000 {
            let payload = index.isMultiple(of: 2) ? "\(index)" : ##""bad""##
            requests.append(VerificationRequest(id: index, type: "ints", payload: payload))
        }
        let report = await registry.verify(batch: requests)

        #expect(report.successCount == 25_000)
        #expect(report.failureCount == 25_000)
        let allIds = Set(report.succeeded).union(report.failed.map { $0.id })
        #expect(allIds.count == 50_000)
    }

    static func isNotRegistered(_ result: SchemaValidationResult) -> Bool {
        guard case .schemaNotRegistered = result else { return false }
        return true
    }

    static func isNotValidJSON(_ result: SchemaValidationResult) -> Bool {
        guard case .instanceNotValidJSON = result else { return false }
        return true
    }
}
