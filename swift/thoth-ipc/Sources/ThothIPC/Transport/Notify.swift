// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Layer 1 of the optional async-receive work, Swift side. **Byte-exact with
// cpp/thoth-ipc/src/thoth-ipc/notify.h and rust/thoth-ipc/src/notify.rs** so a Swift
// `send()` wakes a C++ `async_recv` / Rust `AsyncRoute` (and vice versa). Every
// name derives from one hash, a 16-hex FNV-1a-64 of
// "{prefix}__THOTH_SHM__NOTIFY__{name}". Backends, as C++ notify.h selects them:
//   * macOS: libnotify. `notify_post("thoth.ntf.<hash>")` wakes an fd from
//     `notify_register_file_descriptor` in ANY process, multicast (one post
//     wakes every registered reader).
//   * Linux: a named FIFO `<dir>/thothntf_<hash>.<slot>` per receiver slot
//     (`dir` = $THOTH_IPC_NOTIFY_DIR or /tmp). Point-to-point, so a sender pokes
//     the FIFO of every connected reader slot but its own.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ThothIPCShim

/// 16-hex FNV-1a-64 of make_public_abi_prefix(prefix, "NOTIFY__", name). Byte-exact with C++/Rust.
func notifyHash(_ prefix: String, _ name: String) -> String {
    toHex16(fnv1a64("\(fullPrefix(prefix))NOTIFY__\(name)".utf8))
}

#if os(macOS)

/// libnotify service key for a channel (multicast; one per channel).
func notifyKey(_ prefix: String, _ name: String) -> String {
    "thoth.ntf.\(notifyHash(prefix, name))"
}

/// Writer side: post the channel's key; libnotify multicasts to all readers.
/// `conns` and `selfBit` are for the FIFO backend.
final class NotifySource {
    private var key: String?

    func signal(_ prefix: String, _ name: String, conns: UInt32, selfBit: UInt32) {
        if key == nil { key = notifyKey(prefix, name) }
        key!.withCString { _ = notify_post($0) }
    }
}

/// Reader side: an fd libnotify writes a token to on every matching post.
final class NotifySink {
    private(set) var fd: Int32 = -1
    private var token: Int32 = -1

    var valid: Bool { fd != -1 }

    /// Register the readiness fd for this channel. Idempotent. `slotBit` is for
    /// the FIFO backend.
    @discardableResult
    func open(_ prefix: String, _ name: String, slotBit: UInt32) -> Bool {
        if fd != -1 { return true }
        var f: Int32 = -1
        var t: Int32 = -1
        let status = notifyKey(prefix, name).withCString {
            notify_register_file_descriptor($0, &f, 0, &t)
        }
        guard status == UInt32(NOTIFY_STATUS_OK) else { return false }
        // Non-blocking so drain() never stalls; cloexec for fd hygiene.
        let fl = fcntl(f, F_GETFL, 0)
        if fl != -1 { _ = fcntl(f, F_SETFL, fl | O_NONBLOCK) }
        _ = fcntl(f, F_SETFD, FD_CLOEXEC)
        fd = f
        token = t
        return true
    }

    /// Consume pending token ints after the fd signalled readable (level-triggered).
    func drain() {
        guard fd != -1 else { return }
        var tok: Int32 = 0
        while read(fd, &tok, MemoryLayout<Int32>.size) > 0 {}
    }

    func close() {
        // notify_cancel closes the fd once its last token is cancelled.
        if token != -1 { notify_cancel(token); token = -1 }
        fd = -1
    }

    deinit { close() }
}

/// libnotify keeps no named objects.
func notifyClearStorage(_ prefix: String, _ name: String) {}

#else

/// Max reader connection slots in broadcast mode (C++ `notify_max_slots`).
private let notifyMaxSlots = 32

/// `<dir>/thothntf_<hash>.<slot>` (C++ `notify_fifo_path`).
private func notifyFifoPath(_ prefix: String, _ name: String, _ slot: Int) -> String {
    var dir = "/tmp"
    if let d = getenv("THOTH_IPC_NOTIFY_DIR"), d.pointee != 0 { dir = String(cString: d) }
    return "\(dir)/thothntf_\(notifyHash(prefix, name)).\(slot)"
}

/// Writer side: on enqueue, poke every connected reader slot's FIFO. Write ends
/// are opened lazily and kept until their reader goes away (C++ `notify_source`).
final class NotifySource {
    private var fds = [Int32](repeating: -1, count: notifyMaxSlots)

    private func closeSlot(_ i: Int) {
        if fds[i] != -1 { posixClose(fds[i]); fds[i] = -1 }
    }

    func signal(_ prefix: String, _ name: String, conns: UInt32, selfBit: UInt32) {
        for i in 0..<notifyMaxSlots {
            let bit = UInt32(1) << UInt32(i)
            guard conns & bit != 0, selfBit & bit == 0 else { closeSlot(i); continue }
            if fds[i] == -1 {
                fds[i] = Glibc.open(notifyFifoPath(prefix, name, i), O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                if fds[i] == -1 { continue } // ENXIO: the reader just vanished
            }
            var one: UInt8 = 1
            if thoth_ipc_write_nosigpipe(fds[i], &one, 1) < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                closeSlot(i) // EPIPE/ENXIO: reader gone, reopen next time
            }
            // EAGAIN: an unconsumed wake byte remains, so readiness still holds.
        }
    }

    deinit { for i in 0..<notifyMaxSlots { closeSlot(i) } }
}

/// Reader side: owns the FIFO of this receiver's connection slot (C++
/// `notify_sink`). It keeps its own write end open so the FIFO never reports EOF.
final class NotifySink {
    private(set) var fd: Int32 = -1
    private var wfd: Int32 = -1
    private var path = ""

    var valid: Bool { fd != -1 }

    /// Create and open this slot's FIFO. Idempotent.
    @discardableResult
    func open(_ prefix: String, _ name: String, slotBit: UInt32) -> Bool {
        if fd != -1 { return true }
        guard slotBit != 0 else { return false }
        let slot = slotBit.trailingZeroBitCount
        guard slot < notifyMaxSlots else { return false }
        let p = notifyFifoPath(prefix, name, slot)
        if mkfifo(p, 0o600) != 0 && errno != EEXIST { return false }
        let r = Glibc.open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if r == -1 { unlink(p); return false }
        fd = r
        wfd = Glibc.open(p, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        path = p
        return true
    }

    /// Consume pending wake bytes after the fd signalled readable (level-triggered).
    func drain() {
        guard fd != -1 else { return }
        var buf = [UInt8](repeating: 0, count: 256)
        while read(fd, &buf, buf.count) > 0 {}
    }

    func close() {
        if wfd != -1 { posixClose(wfd); wfd = -1 }
        if fd != -1 { posixClose(fd); fd = -1 }
        if !path.isEmpty { unlink(path); path = "" }
    }

    deinit { close() }
}

/// Remove the FIFO of every reader slot (C++ `notify_clear_storage`).
func notifyClearStorage(_ prefix: String, _ name: String) {
    for slot in 0..<notifyMaxSlots { unlink(notifyFifoPath(prefix, name, slot)) }
}

#endif
