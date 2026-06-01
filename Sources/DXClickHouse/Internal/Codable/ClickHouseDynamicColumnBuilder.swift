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

// Derives a Dynamic column's serialized shape from the per-row element
// types accumulated during encoding. A Dynamic column discovers its
// member type set from the data: the distinct non-null element types,
// sorted into ClickHouse's canonical alphabetical order, become the
// members. The embedded Variant always carries a hidden "SharedVariant"
// member, and ClickHouse assigns every member a global discriminator
// equal to its position in the alphabetically-sorted list of the real
// members plus the SharedVariant. The discriminator a row carries is
// therefore the global discriminator of its member (or 255 for an absent
// row), which the writer must reproduce so the server's per-member value
// counts line up with the sub-columns. The member name list serialized in
// the structure prefix excludes the SharedVariant.
enum ClickHouseDynamicColumnBuilder {

    static let sharedVariantTypeName = "SharedVariant"

    struct Result {

        let members: [ClickHouseArrayElementType]
        let discriminators: [UInt8]
    }

    static func column(elements: [ClickHouseNullable<ClickHouseArrayElementType>], values: [[UInt8]]) -> ClickHouseTypedColumn {
        let result = build(elements: elements)
        return .dynamic(members: result.members, discriminators: result.discriminators, values: values)
    }

    static func build(elements: [ClickHouseNullable<ClickHouseArrayElementType>]) -> Result {
        let members = sortedMembers(elements)
        let globalByMember = globalDiscriminators(of: members)
        let discriminators = mapDiscriminators(elements, members: members, globalByMember: globalByMember)
        return Result(members: members, discriminators: discriminators)
    }

    // Global discriminator for the member at `members[memberIndex]`: its
    // position among the alphabetically-sorted real members plus the
    // SharedVariant placeholder.
    static func globalDiscriminators(of members: [ClickHouseArrayElementType]) -> [UInt8] {
        var names = members.map { $0.typeName }
        names.append(sharedVariantTypeName)
        names.sort()
        var result: [UInt8] = []
        result.reserveCapacity(members.count)
        for member in members {
            result.append(UInt8(positionOf(member.typeName, in: names)))
        }
        return result
    }

    private static func positionOf(_ name: String, in sortedNames: [String]) -> Int {
        for index in sortedNames.indices where sortedNames[index] == name {
            return index
        }
        return sortedNames.count
    }

    private static func sortedMembers(_ elements: [ClickHouseNullable<ClickHouseArrayElementType>]) -> [ClickHouseArrayElementType] {
        var present: [ClickHouseArrayElementType] = []
        for entry in elements {
            if case .present(let element) = entry, !present.contains(element) {
                present.append(element)
            }
        }
        return ClickHouseVariantTypeName.sorted(present)
    }

    private static func mapDiscriminators(
        _ elements: [ClickHouseNullable<ClickHouseArrayElementType>],
        members: [ClickHouseArrayElementType],
        globalByMember: [UInt8]
    ) -> [UInt8] {
        var discriminators: [UInt8] = []
        discriminators.reserveCapacity(elements.count)
        for entry in elements {
            discriminators.append(discriminator(for: entry, members: members, globalByMember: globalByMember))
        }
        return discriminators
    }

    private static func discriminator(
        for entry: ClickHouseNullable<ClickHouseArrayElementType>,
        members: [ClickHouseArrayElementType],
        globalByMember: [UInt8]
    ) -> UInt8 {
        guard case .present(let element) = entry else {
            return 255
        }
        for index in members.indices where members[index] == element {
            return globalByMember[index]
        }
        return 255
    }
}
