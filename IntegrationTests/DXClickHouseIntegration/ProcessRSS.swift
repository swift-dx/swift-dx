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

#if canImport(Darwin)
import Darwin
#endif
import Foundation

// Read the current resident set size (RSS) of the running process,
// in bytes. Used by the integration suite to assert that streaming
// paths do not accumulate memory across iterations.
//
// Darwin: queries the kernel via `task_info(MACH_TASK_BASIC_INFO)`.
// Linux: parses `/proc/self/statm` (RSS column × page size).
//
// Returns 0 on platforms where neither path is available, which the
// caller treats as "skip this assertion" rather than failing the
// test on an unsupported host.
enum ProcessRSS {

    static func currentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.resident_size
        #elseif canImport(Glibc) || canImport(Musl)
        guard let raw = try? String(contentsOfFile: "/proc/self/statm", encoding: .ascii) else {
            return 0
        }
        let parts = raw.split(separator: " ")
        guard parts.count >= 2, let rssPages = UInt64(parts[1]) else { return 0 }
        return rssPages * UInt64(getpagesize())
        #else
        return 0
        #endif
    }

}
