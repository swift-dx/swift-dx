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

import DXClickHouse
import Testing

@Suite("ClickHouseQueryBuilder wire shape")
struct ClickHouseQueryBuilderTest {

    @Test("buildQuery without settings or parameters starts with the Query packet type")
    func minimalQueryShape() throws {
        let bytes = ClickHouseQueryBuilder.buildQuery("SELECT 1")
        #expect(!bytes.isEmpty)
        #expect(bytes[0] == 0x01)
    }

    @Test("buildQuery with a query ID writes the queryID after the packet-type marker")
    func queryIDIsWrittenInsideQueryPacket() throws {
        let bytes = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "abc",
            settings: .empty,
            parameters: .empty,
            revision: ClickHouseQueryBuilder.revision
        )
        #expect(bytes[0] == 0x01)
        #expect(bytes[1] == 0x03)
        #expect(bytes[2] == UInt8(ascii: "a"))
        #expect(bytes[3] == UInt8(ascii: "b"))
        #expect(bytes[4] == UInt8(ascii: "c"))
    }

    @Test("buildQuery surfaces an empty setting name as a typed protocolError")
    func emptySettingNameThrows() {
        let settings = ClickHouseQuerySettings([
            ClickHouseQuerySetting(name: "", value: "x"),
        ])
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            _ = try ClickHouseQueryBuilder.buildQuery(
                "SELECT 1",
                queryID: "",
                settings: settings,
                parameters: .empty,
                revision: ClickHouseQueryBuilder.revision
            )
        } catch let error {
            caught = error
        }
        switch caught {
        case .protocolError(let stage, _):
            #expect(stage == "settings")
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .queryFailed, .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            Issue.record("expected protocolError, got \(caught)")
        }
    }

    @Test("buildQuery surfaces an empty parameter name as a typed protocolError")
    func emptyParameterNameThrows() {
        let parameters = ClickHouseQueryParameters([
            ClickHouseQueryParameter(name: "", value: "x"),
        ])
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            _ = try ClickHouseQueryBuilder.buildQuery(
                "SELECT 1",
                queryID: "",
                settings: .empty,
                parameters: parameters,
                revision: ClickHouseQueryBuilder.revision
            )
        } catch let error {
            caught = error
        }
        switch caught {
        case .protocolError(let stage, _):
            #expect(stage == "parameters")
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .queryFailed, .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            Issue.record("expected protocolError, got \(caught)")
        }
    }

    @Test("buildPing emits the single Ping marker byte")
    func pingShape() {
        let bytes = ClickHouseQueryBuilder.buildPing()
        #expect(bytes == [0x04])
    }

    @Test("buildCancel emits the Cancel marker byte")
    func cancelShape() {
        let bytes = ClickHouseQueryBuilder.buildCancel()
        #expect(bytes == [0x03])
    }

    @Test("buildQuery without settings emits just a terminator at the settings position")
    func emptySettingsTerminator() throws {
        let bytes = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: ClickHouseQueryBuilder.revision
        )
        // Encode-shape check: empty settings vs one setting bumps the
        // buffer length by the encoded triple length.
        let withSetting = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: ClickHouseQuerySettings([
                ClickHouseQuerySetting(name: "max_threads", value: "4"),
            ]),
            parameters: .empty,
            revision: ClickHouseQueryBuilder.revision
        )
        // setting (name=11+1, flag=1, value=1+1) = 15 extra bytes
        #expect(withSetting.count == bytes.count + 15)
    }

    @Test("buildQuery with a parameter increases size vs no parameters")
    func parameterEncodingChangesSize() throws {
        let empty = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: ClickHouseQueryBuilder.revision
        )
        let withParameter = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: ClickHouseQueryParameters([
                ClickHouseQueryParameter(name: "id", value: "42"),
            ]),
            revision: ClickHouseQueryBuilder.revision
        )
        // name(1+2) + customFlag(1) + value(1+2) = 7 extra bytes.
        #expect(withParameter.count == empty.count + 7)
    }

    @Test("buildQuery on older revisions rejects bound parameters rather than dropping them")
    func parametersRejectedOnOldRevision() {
        var threw = false
        do {
            _ = try ClickHouseQueryBuilder.buildQuery(
                "SELECT 1",
                queryID: "",
                settings: .empty,
                parameters: ClickHouseQueryParameters([
                    ClickHouseQueryParameter(name: "id", value: "42"),
                ]),
                revision: 54_000
            )
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test("buildQuery on older revisions still builds when there are no parameters to bind")
    func noParametersBuildsOnOldRevision() throws {
        let withoutParameter = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: 54_000
        )
        #expect(!withoutParameter.isEmpty)
    }

    private func build(at revision: UInt64) throws -> [UInt8] {
        try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: revision
        )
    }

    @Test("clientInfo fields are gated by the negotiated revision, not emitted unconditionally")
    func clientInfoIsRevisionGated() throws {
        // Both revisions sit above the parameters-block gate (54_459), so the
        // only thing that can differ is the clientInfo / roles gating itself:
        // externallyGrantedRoles (54_472), queryNumberOfRows and
        // queryNumberOfLines (54_475), and haveJWT (54_476). This isolates
        // the clientInfo gate from the pre-existing parameters gate.
        let older = try build(at: 54_460)
        let current = try build(at: ClickHouseQueryBuilder.revision)
        #expect(current.count - older.count == 4)
    }

    @Test("query packet size grows monotonically as the negotiated revision rises")
    func querySizeGrowsWithRevision() throws {
        let low = try build(at: 54_400)
        let middle = try build(at: 54_450)
        let high = try build(at: ClickHouseQueryBuilder.revision)
        #expect(low.count <= middle.count)
        #expect(middle.count <= high.count)
    }

    @Test("no field is gated above the client revision, so the field count is stable above it")
    func noFieldGatedAboveClientRevision() throws {
        // Byte-equality would fail because the negotiated revision is itself
        // embedded as the clientTcpProtocolVersion field; both values here
        // encode to a 3-byte varint, so the packet length is identical.
        let atClient = try build(at: ClickHouseQueryBuilder.revision)
        let aboveClient = try build(at: ClickHouseQueryBuilder.revision + 100)
        #expect(atClient.count == aboveClient.count)
    }

    @Test("a revision below every clientInfo gate skips exactly the introduced-later fields")
    func gatedFieldsAccountForExactByteDelta() throws {
        let older = try build(at: 54_440)
        let current = try build(at: ClickHouseQueryBuilder.revision)
        // Fields introduced in (54_440, 54_478] and skipped at 54_440:
        // interserverSecret 54441 (1) + trace 54442 (1) + distributedDepth
        // 54448 (1) + initialQueryStartTime 54449 (8) + parallelReplicas
        // 54453 (3) + parameters-block terminator 54459 (1) +
        // externallyGrantedRoles 54472 (1) + queryNumberOfRows and
        // queryNumberOfLines 54475 (2) + haveJWT 54476 (1) = 19 bytes.
        #expect(current.count - older.count == 19)
    }
}

@Suite("ClickHouseQuerySetting insert deduplication token")
struct ClickHouseInsertDeduplicationTokenTest {

    @Test("insertDeduplicationToken builds the named setting with the important flag")
    func factoryBuildsImportantSetting() {
        let setting = ClickHouseQuerySetting.insertDeduplicationToken("batch-2026-001")
        #expect(setting.name == "insert_deduplication_token")
        #expect(setting.value == "batch-2026-001")
        #expect(setting.important)
        #expect(!setting.custom)
        #expect(!setting.obsolete)
    }

    @Test("an INSERT query carries the dedup token in the settings block")
    func insertQueryEncodesDeduplicationToken() throws {
        let settings = ClickHouseQuerySettings([
            .insertDeduplicationToken("batch-2026-001"),
        ])
        let bytes = try ClickHouseQueryBuilder.buildQuery(
            "INSERT INTO orders (`id`) FORMAT Native",
            queryID: "",
            settings: settings,
            parameters: .empty,
            revision: ClickHouseQueryBuilder.revision
        )
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("insert_deduplication_token"))
        #expect(text.contains("batch-2026-001"))
    }
}

@Suite("ClickHouseProgress and ClickHouseProfileInfo equality")
struct ClickHouseProgressTest {

    @Test("ClickHouseProgress is Equatable and field-preserving")
    func progressEquatable() {
        let a = ClickHouseProgress(rows: 1, bytes: 2, totalRows: 3, totalBytes: 4, writtenRows: 5, writtenBytes: 6, elapsedNanoseconds: 7)
        let b = ClickHouseProgress(rows: 1, bytes: 2, totalRows: 3, totalBytes: 4, writtenRows: 5, writtenBytes: 6, elapsedNanoseconds: 7)
        let c = ClickHouseProgress(rows: 1, bytes: 2, totalRows: 3)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("ClickHouseProfileInfo defaults to no aggregation")
    func profileInfoDefaults() {
        let info = ClickHouseProfileInfo(
            rows: 100,
            blocks: 1,
            bytes: 4096,
            appliedLimit: false,
            rowsBeforeLimit: 0,
            calculatedRowsBeforeLimit: false
        )
        #expect(info.appliedAggregation == false)
        #expect(info.rowsBeforeAggregation == 0)
    }

    @Test("ClickHouseProfileEvents carries host name")
    func profileEventsHostName() {
        let events = ClickHouseProfileEvents(hostName: "node-1")
        #expect(events.hostName == "node-1")
    }
}

@Suite("ClickHouseEndpoint identity")
struct ClickHouseEndpointTest {

    @Test("ClickHouseEndpoint equality and Hashable")
    func endpointEquality() {
        let a = ClickHouseEndpoint(host: "h", port: 9000)
        let b = ClickHouseEndpoint(host: "h", port: 9000)
        let c = ClickHouseEndpoint(host: "h", port: 9001)
        #expect(a == b)
        #expect(a != c)
        var bag: Set<ClickHouseEndpoint> = []
        bag.insert(a)
        bag.insert(b)
        bag.insert(c)
        #expect(bag.count == 2)
    }

    @Test("ClickHouseEndpoint description is host:port")
    func endpointDescription() {
        #expect(ClickHouseEndpoint(host: "h", port: 9000).description == "h:9000")
    }
}
