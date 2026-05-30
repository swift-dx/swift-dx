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

import DXClickHouseRaw
import Testing

@Suite("RawClickHouseQueryBuilder wire shape")
struct RawClickHouseQueryBuilderTest {

    @Test("buildQuery without settings or parameters starts with the Query packet type")
    func minimalQueryShape() throws {
        let bytes = RawClickHouseQueryBuilder.buildQuery("SELECT 1")
        #expect(!bytes.isEmpty)
        #expect(bytes[0] == 0x01)
    }

    @Test("buildQuery with a query ID writes the queryID after the packet-type marker")
    func queryIDIsWrittenInsideQueryPacket() throws {
        let bytes = try RawClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "abc",
            settings: .empty,
            parameters: .empty,
            revision: RawClickHouseQueryBuilder.revision
        )
        #expect(bytes[0] == 0x01)
        #expect(bytes[1] == 0x03)
        #expect(bytes[2] == UInt8(ascii: "a"))
        #expect(bytes[3] == UInt8(ascii: "b"))
        #expect(bytes[4] == UInt8(ascii: "c"))
    }

    @Test("buildQuery surfaces an empty setting name as a typed protocolError")
    func emptySettingNameThrows() {
        let settings = RawClickHouseQuerySettings([
            RawClickHouseQuerySetting(name: "", value: "x"),
        ])
        var caught: RawClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            _ = try RawClickHouseQueryBuilder.buildQuery(
                "SELECT 1",
                queryID: "",
                settings: settings,
                parameters: .empty,
                revision: RawClickHouseQueryBuilder.revision
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
        let parameters = RawClickHouseQueryParameters([
            RawClickHouseQueryParameter(name: "", value: "x"),
        ])
        var caught: RawClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            _ = try RawClickHouseQueryBuilder.buildQuery(
                "SELECT 1",
                queryID: "",
                settings: .empty,
                parameters: parameters,
                revision: RawClickHouseQueryBuilder.revision
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
        let bytes = RawClickHouseQueryBuilder.buildPing()
        #expect(bytes == [0x04])
    }

    @Test("buildCancel emits the Cancel marker byte")
    func cancelShape() {
        let bytes = RawClickHouseQueryBuilder.buildCancel()
        #expect(bytes == [0x03])
    }

    @Test("buildQuery without settings emits just a terminator at the settings position")
    func emptySettingsTerminator() throws {
        let bytes = try RawClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: RawClickHouseQueryBuilder.revision
        )
        // Encode-shape check: empty settings vs one setting bumps the
        // buffer length by the encoded triple length.
        let withSetting = try RawClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: RawClickHouseQuerySettings([
                RawClickHouseQuerySetting(name: "max_threads", value: "4"),
            ]),
            parameters: .empty,
            revision: RawClickHouseQueryBuilder.revision
        )
        // setting (name=11+1, flag=1, value=1+1) = 15 extra bytes
        #expect(withSetting.count == bytes.count + 15)
    }

    @Test("buildQuery with a parameter increases size vs no parameters")
    func parameterEncodingChangesSize() throws {
        let empty = try RawClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: RawClickHouseQueryBuilder.revision
        )
        let withParameter = try RawClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: RawClickHouseQueryParameters([
                RawClickHouseQueryParameter(name: "id", value: "42"),
            ]),
            revision: RawClickHouseQueryBuilder.revision
        )
        // name(1+2) + customFlag(1) + value(1+2) = 7 extra bytes.
        #expect(withParameter.count == empty.count + 7)
    }

    @Test("buildQuery on older revisions skips parameter emission entirely")
    func parametersSkippedOnOldRevision() throws {
        let withParameter = try RawClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: RawClickHouseQueryParameters([
                RawClickHouseQueryParameter(name: "id", value: "42"),
            ]),
            revision: 54_000
        )
        let withoutParameter = try RawClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: 54_000
        )
        #expect(withParameter.count == withoutParameter.count)
    }
}

@Suite("RawClickHouseProgress and RawClickHouseProfileInfo equality")
struct RawClickHouseProgressTest {

    @Test("RawClickHouseProgress is Equatable and field-preserving")
    func progressEquatable() {
        let a = RawClickHouseProgress(rows: 1, bytes: 2, totalRows: 3, totalBytes: 4, writtenRows: 5, writtenBytes: 6, elapsedNanoseconds: 7)
        let b = RawClickHouseProgress(rows: 1, bytes: 2, totalRows: 3, totalBytes: 4, writtenRows: 5, writtenBytes: 6, elapsedNanoseconds: 7)
        let c = RawClickHouseProgress(rows: 1, bytes: 2, totalRows: 3)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("RawClickHouseProfileInfo defaults to no aggregation")
    func profileInfoDefaults() {
        let info = RawClickHouseProfileInfo(
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

    @Test("RawClickHouseProfileEvents carries host name")
    func profileEventsHostName() {
        let events = RawClickHouseProfileEvents(hostName: "node-1")
        #expect(events.hostName == "node-1")
    }
}

@Suite("RawEndpoint identity")
struct RawEndpointTest {

    @Test("RawEndpoint equality and Hashable")
    func endpointEquality() {
        let a = RawEndpoint(host: "h", port: 9000)
        let b = RawEndpoint(host: "h", port: 9000)
        let c = RawEndpoint(host: "h", port: 9001)
        #expect(a == b)
        #expect(a != c)
        var bag: Set<RawEndpoint> = []
        bag.insert(a)
        bag.insert(b)
        bag.insert(c)
        #expect(bag.count == 2)
    }

    @Test("RawEndpoint description is host:port")
    func endpointDescription() {
        #expect(RawEndpoint(host: "h", port: 9000).description == "h:9000")
    }
}
