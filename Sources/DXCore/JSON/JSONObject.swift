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

package struct JSONObject: Sendable {

    package struct Member: Sendable, Equatable {

        package let key: JSONString
        package let value: JSONValue

        package init(key: JSONString, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    package let members: [Member]

    package init(members: [Member]) {
        self.members = members
    }

    package var count: Int {
        members.count
    }

    package var keys: [String] {
        members.map { $0.key.value }
    }

    package func lookup(_ key: String) -> Lookup<JSONValue> {
        for member in members where member.key.equalsString(key) {
            return .found(member.value)
        }
        return .notFound
    }

    package func contains(_ key: String) -> Bool {
        for member in members where member.key.equalsString(key) {
            return true
        }
        return false
    }
}

extension JSONObject: Equatable {

    package static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.members.count == rhs.members.count else { return false }
        return lhs.allMembersMatch(rhs)
    }

    private func allMembersMatch(_ other: JSONObject) -> Bool {
        for member in members where !other.members.contains(member) {
            return false
        }
        return true
    }
}
