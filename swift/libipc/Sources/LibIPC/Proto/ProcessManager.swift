// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/process_manager.h.
// Process spawning and lifecycle management (POSIX / macOS).

import Darwin.POSIX
import LibIPCShim

// MARK: - WaitResult

/// Result of a `waitForExit` call.
public struct WaitResult: Sendable {
    public var exited:   Bool = false
    public var exitCode: Int32 = 0
    public var signaled: Bool = false
    public var signal:   Int32 = 0
}

// MARK: - ProcessHandle

/// Handle to a spawned child process.
public struct ProcessHandle: Sendable {
    public let pid:        pid_t
    public let name:       String
    public let executable: String

    public static let invalid = ProcessHandle(pid: 0, name: "", executable: "")

    public var valid: Bool { pid > 0 }

    public var isAlive: Bool {
        guard valid else { return false }
        return kill(pid, 0) == 0 || errno != ESRCH
    }
}

// MARK: - spawn

/// Spawn a child process using `posix_spawn`.
///
/// - Parameters:
///   - name: Logical label (stored in the handle, used by the service registry).
///   - executable: Path to the binary.
///   - args: Additional command-line arguments.
public func spawn(name: String, executable: String, args: [String] = []) -> ProcessHandle {
    var argv: [UnsafeMutablePointer<CChar>?] = []
    var cStrings: [UnsafeMutablePointer<CChar>] = []

    func makeCStr(_ s: String) -> UnsafeMutablePointer<CChar> {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: s.utf8.count + 1)
        s.withCString { src in buf.initialize(from: src, count: s.utf8.count + 1) }
        return buf
    }

    cStrings.append(makeCStr(executable))
    for a in args { cStrings.append(makeCStr(a)) }
    argv = cStrings.map { Optional($0) }
    argv.append(nil)

    defer { cStrings.forEach { $0.deallocate() } }

    var pid: pid_t = -1
    let err = posix_spawn(&pid, executable, nil, nil, &argv, environ)
    guard err == 0 else { return .invalid }
    return ProcessHandle(pid: pid, name: name, executable: executable)
}

/// Spawn with no extra arguments.
public func spawnSimple(name: String, executable: String) -> ProcessHandle {
    spawn(name: name, executable: executable)
}

// MARK: - Signal helpers

/// Send SIGTERM to request graceful shutdown.
@discardableResult
public func requestShutdown(_ h: ProcessHandle) -> Bool {
    guard h.valid else { return false }
    return kill(h.pid, SIGTERM) == 0
}

/// Send SIGKILL to forcefully terminate.
@discardableResult
public func forceKill(_ h: ProcessHandle) -> Bool {
    guard h.valid else { return false }
    return kill(h.pid, SIGKILL) == 0
}

// MARK: - waitForExit

/// Wait for a process to exit, with a timeout.
public func waitForExit(_ h: ProcessHandle, timeout: Duration) -> WaitResult {
    var r = WaitResult()
    guard h.valid else { return r }
    let deadline = ContinuousClock.now + timeout
    while true {
        var status: Int32 = 0
        let ret = waitpid(h.pid, &status, WNOHANG)
        if ret == h.pid {
            if libipc_wifexited(status)  != 0 { r.exited = true;   r.exitCode = libipc_wexitstatus(status) }
            if libipc_wifsignaled(status) != 0 { r.signaled = true;  r.signal   = libipc_wtermsig(status) }
            return r
        }
        if ret == -1 { return r }
        if ContinuousClock.now >= deadline { return r }
        var ts = timespec(tv_sec: 0, tv_nsec: 10_000_000)
        nanosleep(&ts, nil)
    }
}

// MARK: - shutdown (graceful: SIGTERM → wait → SIGKILL)

/// Gracefully shut down: SIGTERM → wait `grace` → SIGKILL if still alive.
@discardableResult
public func shutdown(_ h: ProcessHandle, grace: Duration) -> WaitResult {
    guard h.valid else { return WaitResult() }
    requestShutdown(h)
    let r = waitForExit(h, timeout: grace)
    if !r.exited && !r.signaled && h.isAlive {
        forceKill(h)
        return waitForExit(h, timeout: .seconds(1))
    }
    return r
}
