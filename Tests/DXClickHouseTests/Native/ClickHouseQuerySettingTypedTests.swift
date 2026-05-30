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
import Testing

@Suite("ClickHouseQuerySetting — typed factories")
struct ClickHouseQuerySettingTypedTests {

    @Test("maxBlockSize emits the documented decimal string under the canonical name")
    func maxBlockSizeWireForm() {
        let setting = ClickHouseQuerySetting.maxBlockSize(1024)
        #expect(setting.name == "max_block_size")
        #expect(setting.value == "1024")
        #expect(setting.important == true,
                "typed factories default to important=true so the server rejects unknown overrides — surfaces typos as errors")
    }

    @Test("maxExecutionTimeSeconds emits a plain decimal string")
    func maxExecutionTimeSecondsWireForm() {
        let setting = ClickHouseQuerySetting.maxExecutionTimeSeconds(30)
        #expect(setting.name == "max_execution_time")
        #expect(setting.value == "30")
    }

    @Test("maxMemoryUsageBytes emits a plain decimal string for byte counts")
    func maxMemoryUsageBytesWireForm() {
        let setting = ClickHouseQuerySetting.maxMemoryUsageBytes(10_000_000_000)
        #expect(setting.name == "max_memory_usage")
        #expect(setting.value == "10000000000")
    }

    @Test("maxThreads pins the canonical name")
    func maxThreadsWireForm() {
        let setting = ClickHouseQuerySetting.maxThreads(8)
        #expect(setting.name == "max_threads")
        #expect(setting.value == "8")
    }

    @Test("maxResultRows pins the canonical name and a large value")
    func maxResultRowsWireForm() {
        let setting = ClickHouseQuerySetting.maxResultRows(1_000_000)
        #expect(setting.name == "max_result_rows")
        #expect(setting.value == "1000000")
    }

    @Test("booleans encode as '0' or '1' for asyncInsert", arguments: [(false, "0"), (true, "1")])
    func asyncInsertWireForm(input: Bool, expected: String) {
        let setting = ClickHouseQuerySetting.asyncInsert(input)
        #expect(setting.name == "async_insert")
        #expect(setting.value == expected)
    }

    @Test("waitForAsyncInsert encodes as '0' or '1'", arguments: [(false, "0"), (true, "1")])
    func waitForAsyncInsertWireForm(input: Bool, expected: String) {
        let setting = ClickHouseQuerySetting.waitForAsyncInsert(input)
        #expect(setting.name == "wait_for_async_insert")
        #expect(setting.value == expected)
    }

    @Test("waitForAsyncInsertTimeoutSeconds wire form")
    func waitForAsyncInsertTimeoutWireForm() {
        let setting = ClickHouseQuerySetting.waitForAsyncInsertTimeoutSeconds(30)
        #expect(setting.name == "wait_for_async_insert_timeout")
        #expect(setting.value == "30")
    }

    @Test("functionSleepMaxMicrosecondsPerBlock wire form")
    func functionSleepWireForm() {
        let setting = ClickHouseQuerySetting.functionSleepMaxMicrosecondsPerBlock(5_000_000)
        #expect(setting.name == "function_sleep_max_microseconds_per_block")
        #expect(setting.value == "5000000")
    }

    @Test(
        "readonly maps each enum case to its server-side integer code",
        arguments: [
            (ClickHouseQuerySetting.ReadonlyMode.readWrite, "0"),
            (.readOnly, "1"),
            (.readOnlyWithSettingChanges, "2"),
        ]
    )
    func readonlyWireForm(mode: ClickHouseQuerySetting.ReadonlyMode, expected: String) {
        let setting = ClickHouseQuerySetting.readonly(mode)
        #expect(setting.name == "readonly")
        #expect(setting.value == expected)
    }

    @Test("insertDeduplicate encodes as '0' or '1'", arguments: [(false, "0"), (true, "1")])
    func insertDeduplicateWireForm(input: Bool, expected: String) {
        let setting = ClickHouseQuerySetting.insertDeduplicate(input)
        #expect(setting.name == "insert_deduplicate")
        #expect(setting.value == expected)
    }

    @Test("typed factories don't conflict with the raw initializer — both can coexist in the same settings array")
    func typedAndRawCoexist() {
        let settings: [ClickHouseQuerySetting] = [
            .maxBlockSize(1024),
            .init(name: "compile_expressions", value: "1"),
            .asyncInsert(true),
        ]
        #expect(settings.count == 3)
        #expect(settings[0].name == "max_block_size")
        #expect(settings[1].name == "compile_expressions")
        #expect(settings[2].name == "async_insert")
    }

    @Test("maxRowsToRead maps to 'max_rows_to_read' for read-cap enforcement")
    func maxRowsToReadMaps() {
        let setting = ClickHouseQuerySetting.maxRowsToRead(1_000_000)
        #expect(setting.name == "max_rows_to_read")
        #expect(setting.value == "1000000")
    }

    @Test("maxBytesToRead maps to 'max_bytes_to_read'")
    func maxBytesToReadMaps() {
        let setting = ClickHouseQuerySetting.maxBytesToRead(2_000_000_000)
        #expect(setting.name == "max_bytes_to_read")
        #expect(setting.value == "2000000000")
    }

    @Test("maxResultBytes maps to 'max_result_bytes'")
    func maxResultBytesMaps() {
        let setting = ClickHouseQuerySetting.maxResultBytes(1_000_000)
        #expect(setting.name == "max_result_bytes")
        #expect(setting.value == "1000000")
    }

    @Test("sendTimeoutSeconds and receiveTimeoutSeconds map to their separate settings")
    func sendAndReceiveTimeoutsMap() {
        let send = ClickHouseQuerySetting.sendTimeoutSeconds(60)
        let recv = ClickHouseQuerySetting.receiveTimeoutSeconds(60)
        #expect(send.name == "send_timeout")
        #expect(recv.name == "receive_timeout")
        #expect(send.value == "60")
        #expect(recv.value == "60")
    }

    @Test("sendLogsLevel uses the raw string of ClickHouseLogLevel enum cases")
    func sendLogsLevelMaps() {
        #expect(ClickHouseQuerySetting.sendLogsLevel(.none).value == "none")
        #expect(ClickHouseQuerySetting.sendLogsLevel(.warning).value == "warning")
        #expect(ClickHouseQuerySetting.sendLogsLevel(.trace).value == "trace")
        #expect(ClickHouseQuerySetting.sendLogsLevel(.debug).value == "debug")
        #expect(ClickHouseQuerySetting.sendLogsLevel(.error).value == "error")
        #expect(ClickHouseQuerySetting.sendLogsLevel(.fatal).value == "fatal")
        #expect(ClickHouseQuerySetting.sendLogsLevel(.information).value == "information")
        #expect(ClickHouseQuerySetting.sendLogsLevel(.test).value == "test")
    }

    @Test("ClickHouseLogLevel covers all eight server-defined levels")
    func logLevelEnumIsExhaustive() {
        #expect(ClickHouseLogLevel.allCases.count == 8)
    }

    @Test("resultOverflowMode .throw and .break map to the documented server values")
    func overflowModeMaps() {
        #expect(ClickHouseQuerySetting.resultOverflowMode(.throw).value == "throw")
        #expect(ClickHouseQuerySetting.resultOverflowMode(.break).value == "break")
    }

    @Test("ClickHouseOverflowMode has both 'throw' and 'break' cases")
    func overflowModeIsExhaustive() {
        #expect(ClickHouseOverflowMode.allCases.count == 2)
        let names = ClickHouseOverflowMode.allCases.map(\.rawValue).sorted()
        #expect(names == ["break", "throw"])
    }

    @Test("a typed factory and the raw initializer with the same name and value are Equatable equal")
    func factoryEqualsRawConstruction() {
        let viaFactory = ClickHouseQuerySetting.maxExecutionTimeSeconds(30)
        let viaRaw = ClickHouseQuerySetting(name: "max_execution_time", value: "30")
        #expect(viaFactory == viaRaw)
    }

}
