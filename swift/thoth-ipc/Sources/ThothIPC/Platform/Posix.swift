// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// libc calls that some types shadow with a member of the same name (close,
// time), qualified by the platform's C module.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ThothIPCShim

@inline(__always) @discardableResult
func posixClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

@inline(__always)
func posixTime() -> Int64 {
    #if canImport(Darwin)
    Int64(Darwin.time(nil))
    #else
    Int64(Glibc.time(nil))
    #endif
}

/// `d` in nanoseconds, saturating; negative durations are 0.
func durationNs(_ d: Duration) -> Int64 {
    let c = d.components
    if c.seconds < 0 { return 0 }
    let (s, o) = c.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    if o { return .max }
    let (t, o2) = s.addingReportingOverflow(c.attoseconds / 1_000_000_000)
    return o2 ? .max : t
}

/// The C stdout and stderr streams, readable from Swift 6 code on every
/// platform (Glibc declares the globals mutable).
public var stdoutStream: UnsafeMutablePointer<FILE> { thoth_ipc_stdout() }
public var stderrStream: UnsafeMutablePointer<FILE> { thoth_ipc_stderr() }
