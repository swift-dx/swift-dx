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

@testable import DXClickHouse
import NIOCore
import Testing

@Suite("ClickHouse query lifecycle")
struct ClickHouseQueryLifecycleTests {

    private let lifecycle = ClickHouseQueryLifecycle(revision: 54_478)

    private func makeBlock() -> ClickHouseBlock {
        ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "x", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1, 2])),
            ]
        )
    }

    @Test("data packet translates to .data event with the block preserved")
    func dataTranslatesToDataEvent() throws {
        let block = makeBlock()
        let event = try lifecycle.handle(.data(tableName: "schema.table", block: block))
        guard case .data(let decodedBlock) = event else {
            Issue.record("expected .data, got \(event)")
            return
        }
        let firstColumn = try #require(decodedBlock.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(firstColumn.values == [1, 2])
    }

    @Test("totals, extremes, log, and profile events all translate to their typed events")
    func blockCarryingPacketsTranslateCorrectly() throws {
        let block = makeBlock()
        let cases: [(ClickHouseServerPacket, String)] = [
            (.totals(tableName: "", block: block), "totals"),
            (.extremes(tableName: "", block: block), "extremes"),
            (.log(tableName: "", block: block), "log"),
            (.profileEvents(tableName: "", block: block), "profileEvents"),
        ]
        for (packet, label) in cases {
            let event = try lifecycle.handle(packet)
            switch (label, event) {
            case ("totals", .totals): break
            case ("extremes", .extremes): break
            case ("log", .log): break
            case ("profileEvents", .profileEvents): break
            default: Issue.record("\(label) translated to wrong event \(event)")
            }
        }
    }

    @Test("progress, profileInfo, tableColumns translate to their typed events with payloads preserved")
    func metadataPacketsTranslateCorrectly() throws {
        let progress = ClickHouseServerProgressPacket(rows: 100, bytes: 4_000, totalRows: 100, writtenRows: .unsupported, writtenBytes: .unsupported)
        let progressEvent = try lifecycle.handle(.progress(progress))
        guard case .progress(let decodedProgress) = progressEvent else {
            Issue.record("expected .progress")
            return
        }
        #expect(decodedProgress.rows == 100)

        let profileInfo = ClickHouseServerProfileInfoPacket(
            rows: 50, blocks: 1, bytes: 2_000,
            appliedLimit: false, rowsBeforeLimit: 0, calculatedRowsBeforeLimit: false
        )
        let profileEvent = try lifecycle.handle(.profileInfo(profileInfo))
        guard case .profileInfo(let decoded) = profileEvent else {
            Issue.record("expected .profileInfo")
            return
        }
        #expect(decoded.rows == 50)

        let tableColumns = ClickHouseServerTableColumnsPacket(
            name: "logs", columnsText: "id UUID, ts DateTime64(9, 'UTC')"
        )
        let columnsEvent = try lifecycle.handle(.tableColumns(tableColumns))
        guard case .tableColumns(let decodedColumns) = columnsEvent else {
            Issue.record("expected .tableColumns")
            return
        }
        #expect(decodedColumns.name == "logs")
    }

    @Test("endOfStream translates to .completed")
    func endOfStreamCompletes() throws {
        let event = try lifecycle.handle(.endOfStream)
        guard case .completed = event else {
            Issue.record("expected .completed")
            return
        }
    }

    @Test("exception translates to .failed with the typed exception preserved")
    func exceptionTranslatesToFailed() throws {
        let exception = ClickHouseServerExceptionPacket(
            code: 60, name: "DB::TableNotFound", message: "no such table", stackTrace: "", nested: .none
        )
        let event = try lifecycle.handle(.exception(exception))
        guard case .failed(let decoded) = event else {
            Issue.record("expected .failed")
            return
        }
        #expect(decoded == exception)
    }

    @Test("hello packet during query phase surfaces a typed protocol error")
    func helloDuringQueryRejected() {
        let serverHello = ClickHouseServerHelloPacket(
            serverName: "ClickHouse", versionMajor: 24, versionMinor: 8,
            serverRevision: 54_478,
            serverTimezone: .value("UTC"), displayName: .value("ch-1"), versionPatch: .value(12)
        )
        #expect {
            try lifecycle.handle(.hello(serverHello))
        } throws: { error in
            guard case ClickHouseError.unexpectedPacketDuringQuery(let received) = error else {
                return false
            }
            return received == "hello"
        }
    }

    @Test("pong packet during query phase surfaces a typed protocol error")
    func pongDuringQueryRejected() {
        #expect {
            try lifecycle.handle(.pong)
        } throws: { error in
            guard case ClickHouseError.unexpectedPacketDuringQuery(let received) = error else {
                return false
            }
            return received == "pong"
        }
    }

    @Test("readTaskRequest during query phase surfaces a typed protocol error")
    func readTaskRequestDuringQueryRejected() {
        #expect {
            try lifecycle.handle(.readTaskRequest)
        } throws: { error in
            guard case ClickHouseError.unexpectedPacketDuringQuery(let received) = error else {
                return false
            }
            return received == "readTaskRequest"
        }
    }

    @Test("a realistic SELECT response sequence can be driven through the lifecycle to completion")
    func selectResponseSequenceCompletes() throws {
        let block = makeBlock()
        let progress = ClickHouseServerProgressPacket(rows: 2, bytes: 8, totalRows: 2, writtenRows: .unsupported, writtenBytes: .unsupported)
        let profileInfo = ClickHouseServerProfileInfoPacket(
            rows: 2, blocks: 1, bytes: 8,
            appliedLimit: false, rowsBeforeLimit: 0, calculatedRowsBeforeLimit: false
        )

        let sequence: [ClickHouseServerPacket] = [
            .data(tableName: "", block: block),
            .progress(progress),
            .profileInfo(profileInfo),
            .endOfStream,
        ]

        var sawData = false
        var sawProgress = false
        var sawProfileInfo = false
        var completed = false

        for packet in sequence {
            let event = try lifecycle.handle(packet)
            switch event {
            case .data: sawData = true
            case .progress: sawProgress = true
            case .profileInfo: sawProfileInfo = true
            case .completed: completed = true
            default: Issue.record("unexpected event \(event)")
            }
        }

        #expect(sawData)
        #expect(sawProgress)
        #expect(sawProfileInfo)
        #expect(completed)
    }

    @Test("an exception terminator interrupts the lifecycle as a .failed event before completion")
    func exceptionInterruptsLifecycle() throws {
        let block = makeBlock()
        let exception = ClickHouseServerExceptionPacket(
            code: 159, name: "DB::Timeout", message: "timed out", stackTrace: "", nested: .none
        )

        let firstEvent = try lifecycle.handle(.data(tableName: "", block: block))
        guard case .data = firstEvent else {
            Issue.record("expected .data")
            return
        }

        let secondEvent = try lifecycle.handle(.exception(exception))
        guard case .failed(let decoded) = secondEvent else {
            Issue.record("expected .failed")
            return
        }
        #expect(decoded.code == 159)
    }

}
