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

import DXCore
import DXJSONSchema

enum ComplianceRunner {

    static func run(_ files: [SuiteFile], resources: [SchemaResource]) -> ComplianceReport {
        var report = ComplianceReport()
        for file in files {
            runFile(file, resources, into: &report)
        }
        return report
    }

    static func runFile(_ file: SuiteFile, _ resources: [SchemaResource], into report: inout ComplianceReport) {
        guard !ComplianceSkiplist.skipsFile(file.name) else {
            report.skippedFiles += 1
            return
        }
        for group in file.groups {
            runGroup(file.name, group, resources, into: &report)
        }
    }

    static func runGroup(_ fileName: String, _ group: JSONValue, _ resources: [SchemaResource], into report: inout ComplianceReport) {
        guard case .object(let object) = group else { return }
        evaluateGroup(fileName, object, resources, into: &report)
    }

    static func evaluateGroup(_ fileName: String, _ object: JSONObject, _ resources: [SchemaResource], into report: inout ComplianceReport) {
        let groupDesc = stringMember(object, "description")
        guard !ComplianceSkiplist.skipsGroup(fileName, groupDesc) else {
            report.skippedCases += 1
            return
        }
        guard case .found(let schemaValue) = object.lookup("schema") else { return }
        compileAndRun(fileName, groupDesc, schemaValue, object, resources, into: &report)
    }

    static func compileAndRun(_ fileName: String, _ groupDesc: String, _ schemaValue: JSONValue, _ object: JSONObject, _ resources: [SchemaResource], into report: inout ComplianceReport) {
        do {
            let schema = try JSONSchema.compile(JSONValueWriter.write(schemaValue), resources: resources)
            runTests(fileName, groupDesc, schema, object, into: &report)
        } catch {
            recordCompileFailure(fileName, groupDesc, error, into: &report)
        }
    }

    static func runTests(_ fileName: String, _ groupDesc: String, _ schema: JSONSchema, _ object: JSONObject, into report: inout ComplianceReport) {
        guard case .found(.array(let tests)) = object.lookup("tests") else { return }
        for test in tests {
            runTest(fileName, groupDesc, schema, test, into: &report)
        }
    }

    static func runTest(_ fileName: String, _ groupDesc: String, _ schema: JSONSchema, _ test: JSONValue, into report: inout ComplianceReport) {
        guard case .object(let testObject) = test else { return }
        evaluateTest(fileName, groupDesc, schema, testObject, into: &report)
    }

    static func evaluateTest(_ fileName: String, _ groupDesc: String, _ schema: JSONSchema, _ testObject: JSONObject, into report: inout ComplianceReport) {
        let testDesc = stringMember(testObject, "description")
        guard !ComplianceSkiplist.skipsCase(fileName, groupDesc, testDesc) else {
            report.skippedCases += 1
            return
        }
        checkTest(fileName, groupDesc, testDesc, schema, testObject, into: &report)
    }

    static func checkTest(_ fileName: String, _ groupDesc: String, _ testDesc: String, _ schema: JSONSchema, _ testObject: JSONObject, into report: inout ComplianceReport) {
        guard case .found(let dataValue) = testObject.lookup("data"), case .found(.bool(let expected)) = testObject.lookup("valid") else { return }
        let result = schema.validate(JSONValueWriter.write(dataValue))
        recordOutcome(fileName, groupDesc, testDesc, result.isValid, expected, into: &report)
    }

    static func recordOutcome(_ fileName: String, _ groupDesc: String, _ testDesc: String, _ actual: Bool, _ expected: Bool, into report: inout ComplianceReport) {
        guard actual != expected else {
            report.passed += 1
            return
        }
        report.failures.append(ComplianceFailure(file: fileName, group: groupDesc, test: testDesc, detail: "expected valid=\(expected) got \(actual)"))
    }

    static func recordCompileFailure(_ fileName: String, _ groupDesc: String, _ error: JSONSchemaError, into report: inout ComplianceReport) {
        report.failures.append(ComplianceFailure(file: fileName, group: groupDesc, test: "(schema compile)", detail: error.description))
    }

    static func stringMember(_ object: JSONObject, _ key: String) -> String {
        guard case .found(.string(let value)) = object.lookup(key) else { return "" }
        return value.value
    }
}
