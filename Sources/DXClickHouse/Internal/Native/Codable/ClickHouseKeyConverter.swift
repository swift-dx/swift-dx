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

// Pure conversion helper between Swift's camelCase property naming
// and ClickHouse's commonly-used snake_case column naming.
//
// Implementation matches Foundation's JSONEncoder/JSONDecoder
// snake_case strategies so calling code can rely on identical
// semantics. The algorithm splits on:
//   - The lower-to-upper transition, so "kinesisShardId" becomes
//     "kinesis_shard_id" and "urlPath" becomes "url_path".
//   - The boundary where a run of >1 uppercase letters meets a
//     following lowercase letter (the "acronym in front of a word"
//     case), so "myURLPath" becomes "my_url_path" and
//     "kinesisURLEncoded" becomes "kinesis_url_encoded". Pre-fix
//     this boundary was silently missed and the column name diverged
//     from what Foundation's JSONEncoder would have produced.
//
// Digit boundaries are NOT treated as word starts (matches
// Foundation): "scope2" stays "scope2".
enum ClickHouseKeyConverter {

    // camelCase → snake_case. Exposed for both encode and decode
    // strategies (decode looks up snake_case from a Swift key, so
    // it's the same conversion as encode).
    static func swiftToSnakeCase(_ swiftKey: String) -> String {
        guard !swiftKey.isEmpty else { return swiftKey }
        var words: [Range<String.Index>] = []
        var wordStart = swiftKey.startIndex
        var searchRange = swiftKey.index(after: wordStart)..<swiftKey.endIndex
        accumulateSnakeCaseWords(swiftKey: swiftKey, words: &words, wordStart: &wordStart, searchRange: &searchRange)
        words.append(wordStart..<searchRange.upperBound)
        return words.map { swiftKey[$0].lowercased() }.joined(separator: "_")
    }

    private static func accumulateSnakeCaseWords(
        swiftKey: String,
        words: inout [Range<String.Index>],
        wordStart: inout String.Index,
        searchRange: inout Range<String.Index>
    ) {
        while let upperCaseRange = swiftKey.rangeOfCharacter(from: .uppercaseLetters, options: [], range: searchRange) {
            words.append(wordStart..<upperCaseRange.lowerBound)
            searchRange = upperCaseRange.lowerBound..<swiftKey.endIndex
            guard let lowerCaseRange = swiftKey.rangeOfCharacter(from: .lowercaseLetters, options: [], range: searchRange) else {
                wordStart = searchRange.lowerBound
                return
            }
            splitAtUpperLowerBoundary(swiftKey: swiftKey, upperCaseRange: upperCaseRange, lowerCaseRange: lowerCaseRange, words: &words, wordStart: &wordStart)
            searchRange = lowerCaseRange.upperBound..<searchRange.upperBound
        }
    }

    private static func splitAtUpperLowerBoundary(
        swiftKey: String,
        upperCaseRange: Range<String.Index>,
        lowerCaseRange: Range<String.Index>,
        words: inout [Range<String.Index>],
        wordStart: inout String.Index
    ) {
        let nextAfterUpper = swiftKey.index(after: upperCaseRange.lowerBound)
        if lowerCaseRange.lowerBound == nextAfterUpper {
            wordStart = upperCaseRange.lowerBound
        } else {
            let beforeLower = swiftKey.index(before: lowerCaseRange.lowerBound)
            words.append(upperCaseRange.lowerBound..<beforeLower)
            wordStart = beforeLower
        }
    }

}
