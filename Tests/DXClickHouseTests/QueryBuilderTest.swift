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
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .queryFailed, .reconnectExhausted, .endpointsExhausted:
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
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .queryFailed, .reconnectExhausted, .endpointsExhausted:
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

    @Test("buildQuery on older revisions skips parameter emission entirely")
    func parametersSkippedOnOldRevision() throws {
        let withParameter = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: ClickHouseQueryParameters([
                ClickHouseQueryParameter(name: "id", value: "42"),
            ]),
            revision: 54_000
        )
        let withoutParameter = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: 54_000
        )
        #expect(withParameter.count == withoutParameter.count)
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
