// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Layer 1 of the optional async-receive work, Swift side. **Byte-exact with
// cpp/thoth-ipc/src/thoth-ipc/notify.h and rust/thoth-ipc/src/notify.rs** so a Swift
// `send()` wakes a C++ `async_recv` / Rust `AsyncRoute` (and vice versa). Swift
// is macOS-only, so this is the Darwin libnotify backend: `notify_post(key)`
// wakes an fd from `notify_register_file_descriptor(key, ...)` in ANY process,
// multicast (one post wakes every registered reader), one key per channel.
//
// The key is `"ipc.ntf." + 16-hex FNV-1a-64 of "{prefix}__IPC_SHM__NOTIFY__{name}"`.

import Darwin
import ThothIPCShim

/// 16-hex FNV-1a-64 of make_public_abi_prefix(prefix, "NOTIFY__", name). Byte-exact with C++/Rust.
func notifyHash(_ prefix: String, _ name: String) -> String {
    toHex16(fnv1a64("\(fullPrefix(prefix))NOTIFY__\(name)".utf8))
}

/// libnotify service key for a channel (multicast; one per channel).
func notifyKey(_ prefix: String, _ name: String) -> String {
    "ipc.ntf.\(notifyHash(prefix, name))"
}

/// Writer side: post the channel's key; libnotify multicasts to all readers.
final class NotifySource {
    private var key: String?

    func signal(_ prefix: String, _ name: String) {
        if key == nil { key = notifyKey(prefix, name) }
        key!.withCString { _ = notify_post($0) }
    }
}

/// Reader side: an fd libnotify writes a token to on every matching post.
final class NotifySink {
    private(set) var fd: Int32 = -1
    private var token: Int32 = -1

    var valid: Bool { fd != -1 }

    /// Register the readiness fd for this channel. Idempotent.
    @discardableResult
    func open(_ prefix: String, _ name: String) -> Bool {
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
