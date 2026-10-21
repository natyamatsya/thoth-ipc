// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Layer 1 notify readiness (ABI §8). A sender signals on enqueue; an async
// receiver owns a readiness fd and wakes on the signal. Naming is byte-exact
// across languages, so a Zig sender wakes a C++/Rust/Swift async receiver and
// vice versa. Every name derives from one hash:
//   hash = 16-hex(fnv1a_64("{prefix}__THOTH_SHM__NOTIFY__{name}"))
// Golden: ("","xchan") -> 098e889ce378ae04 (unit-tested in shmname.zig).
//
// Backends (as C++ notify.h selects them):
//   * macOS -> libnotify: `notify_post("thoth.ntf.<hash>")` wakes an fd from
//     `notify_register_file_descriptor` in ANY process. Multicast — one post
//     wakes every registered reader.
//   * Linux -> named FIFO `<dir>/thothntf_<hash>.<slot>`, one per receiver
//     connection slot (`dir` = $THOTH_IPC_NOTIFY_DIR or /tmp). Point-to-point,
//     so a sender pokes the FIFO of every connected reader slot but its own.
//
// API (both backends):
//   Source{}.signal(prefix, name, conns, self_bit)   Source.close()
//   Sink.open(prefix, name, slot_bit)  .valid  .wait(ms)  .drain()  .close()

const std = @import("std");
const builtin = @import("builtin");
const shmname = @import("../platform/shmname.zig");

pub const Source = switch (builtin.os.tag) {
    .linux => fifo.Source,
    .macos => libnotify.Source,
    else => @compileError("thoth-ipc: no notify backend for " ++ @tagName(builtin.os.tag)),
};

pub const Sink = switch (builtin.os.tag) {
    .linux => fifo.Sink,
    .macos => libnotify.Sink,
    else => @compileError("thoth-ipc: no notify backend for " ++ @tagName(builtin.os.tag)),
};

/// The channel's 16-hex notify hash (C++ `notify_hash`).
fn notifyHash(prefix: []const u8, name: []const u8) [16]u8 {
    var sbuf: [256]u8 = undefined;
    const id = std.fmt.bufPrint(&sbuf, "{s}__THOTH_SHM__NOTIFY__{s}", .{ prefix, name }) catch unreachable;
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{shmname.fnv1a64(id)}) catch unreachable;
    return out;
}

/// Block until `fd` is readable or `timeout_ms` elapses. True if readable.
fn pollReadable(fd: c_int, timeout_ms: i32) bool {
    var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    const n = std.c.poll(&pfd, 1, timeout_ms);
    return n > 0 and (pfd[0].revents & std.c.POLL.IN) != 0;
}

/// Read until `fd` (non-blocking) has nothing left.
fn drainFd(fd: c_int) void {
    var scratch: [256]u8 = undefined;
    while (std.c.read(fd, &scratch, scratch.len) > 0) {}
}

const libnotify = struct {
    const NOTIFY_STATUS_OK: u32 = 0;

    // libnotify (libSystem) — private-but-stable notification service.
    extern "c" fn notify_post(name: [*:0]const u8) u32;
    extern "c" fn notify_register_file_descriptor(name: [*:0]const u8, notify_fd: *c_int, flags: c_int, out_token: *c_int) u32;
    extern "c" fn notify_cancel(token: c_int) u32;

    /// `thoth.ntf.<hash>`, NUL-terminated in `buf`.
    fn serviceKey(buf: *[32]u8, prefix: []const u8, name: []const u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "thoth.ntf.{s}", .{notifyHash(prefix, name)}, 0) catch unreachable;
    }

    const Source = struct {
        /// Post the readiness signal. A no-op if nobody is listening, so it is
        /// cheap to call on every send. `conns`/`self_bit` are unused: posts
        /// are multicast.
        pub fn signal(_: *@This(), prefix: []const u8, name: []const u8, conns: u32, self_bit: u32) void {
            _ = .{ conns, self_bit };
            var buf: [32]u8 = undefined;
            _ = notify_post(serviceKey(&buf, prefix, name).ptr);
        }

        pub fn close(_: *@This()) void {}
    };

    /// A receiver's readiness fd — signalled (a 4-byte token per post) whenever
    /// any language's sender posts. Level-triggered: drain after a wake.
    const Sink = struct {
        fd: c_int = -1,
        token: c_int = 0,
        valid: bool = false,

        /// `slot_bit` is unused: posts are multicast.
        pub fn open(prefix: []const u8, name: []const u8, slot_bit: u32) @This() {
            _ = slot_bit;
            var buf: [32]u8 = undefined;
            var self: @This() = .{};
            if (notify_register_file_descriptor(serviceKey(&buf, prefix, name).ptr, &self.fd, 0, &self.token) != NOTIFY_STATUS_OK) return self;
            // Non-blocking so drain() can read tokens until they run out.
            const fl = std.c.fcntl(self.fd, std.c.F.GETFL, @as(c_int, 0));
            _ = std.c.fcntl(self.fd, std.c.F.SETFL, fl | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
            self.valid = true;
            return self;
        }

        pub fn wait(self: *const @This(), timeout_ms: i32) bool {
            return pollReadable(self.fd, timeout_ms);
        }

        pub fn drain(self: *const @This()) void {
            drainFd(self.fd);
        }

        pub fn close(self: *@This()) void {
            if (!self.valid) return;
            // notify_cancel closes the fd once its last token is cancelled.
            _ = notify_cancel(self.token);
            self.valid = false;
        }
    };
};

const fifo = struct {
    const linux = std.os.linux;

    /// Max reader connection slots in broadcast mode (C++ `notify_max_slots`).
    const max_slots = 32;

    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

    /// `<dir>/thothntf_<hash>.<slot>`, NUL-terminated in `buf` (C++
    /// `notify_fifo_path`).
    fn fifoPath(buf: *[std.fs.max_path_bytes]u8, prefix: []const u8, name: []const u8, slot: usize) [:0]const u8 {
        const dir = if (std.c.getenv("THOTH_IPC_NOTIFY_DIR")) |d| std.mem.span(d) else "";
        return std.fmt.bufPrintSentinel(buf, "{s}/thothntf_{s}.{d}", .{
            if (dir.len == 0) "/tmp" else dir, notifyHash(prefix, name), slot,
        }, 0) catch unreachable;
    }

    fn openFlags(acc: std.c.O) std.c.O {
        var o = acc;
        o.NONBLOCK = true;
        o.CLOEXEC = true;
        return o;
    }

    /// Writing to a FIFO whose reader is gone raises SIGPIPE, and Linux has no
    /// per-fd opt-out: block it for the write, and consume one we caused
    /// before restoring the mask (C++ `notify_sigpipe_guard`).
    const SigpipeGuard = struct {
        old: linux.sigset_t,

        fn begin() SigpipeGuard {
            var set = linux.sigemptyset();
            linux.sigaddset(&set, .PIPE);
            var self: SigpipeGuard = undefined;
            _ = linux.sigprocmask(linux.SIG.BLOCK, &set, &self.old);
            return self;
        }

        fn end(self: *const SigpipeGuard) void {
            var pending = linux.sigemptyset();
            _ = linux.syscall2(.rt_sigpending, @intFromPtr(&pending), linux.NSIG / 8);
            if (linux.sigismember(&pending, .PIPE) and !linux.sigismember(&self.old, .PIPE)) {
                var only = linux.sigemptyset();
                linux.sigaddset(&only, .PIPE);
                const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
                _ = linux.syscall4(.rt_sigtimedwait, @intFromPtr(&only), 0, @intFromPtr(&zero), linux.NSIG / 8);
            }
            _ = linux.sigprocmask(linux.SIG.SETMASK, &self.old, null);
        }
    };

    /// Writer side: on enqueue, poke every connected reader slot's FIFO. Write
    /// ends are opened lazily and kept until their reader goes away.
    const Source = struct {
        fds: [max_slots]c_int = @splat(-1),

        pub fn signal(self: *@This(), prefix: []const u8, name: []const u8, conns: u32, self_bit: u32) void {
            for (&self.fds, 0..) |*fd, i| {
                const bit = @as(u32, 1) << @intCast(i);
                if (conns & bit == 0 or self_bit & bit != 0) {
                    closeFd(fd); // drop a stale slot
                    continue;
                }
                if (fd.* == -1) {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    // ENXIO until the reader has the FIFO open; try next time.
                    fd.* = std.c.open(fifoPath(&buf, prefix, name, i).ptr, openFlags(.{ .ACCMODE = .WRONLY }));
                    if (fd.* == -1) continue;
                }
                const guard = SigpipeGuard.begin();
                defer guard.end();
                const byte = [_]u8{1};
                if (std.c.write(fd.*, &byte, 1) < 0) switch (std.posix.errno(-1)) {
                    // An unconsumed wake byte is still there: readiness holds.
                    .AGAIN => {},
                    // EPIPE / ENXIO: the reader is gone; reopen next time.
                    else => closeFd(fd),
                };
            }
        }

        pub fn close(self: *@This()) void {
            for (&self.fds) |*fd| closeFd(fd);
        }

        fn closeFd(fd: *c_int) void {
            if (fd.* == -1) return;
            _ = std.c.close(fd.*);
            fd.* = -1;
        }
    };

    /// Reader side: owns the FIFO for this receiver's connection slot. It also
    /// holds a write end itself, so the FIFO never reports EOF between senders.
    const Sink = struct {
        rfd: c_int = -1,
        wfd: c_int = -1,
        valid: bool = false,
        path_buf: [std.fs.max_path_bytes]u8 = undefined,
        path_len: usize = 0,

        pub fn open(prefix: []const u8, name: []const u8, slot_bit: u32) @This() {
            var self: @This() = .{};
            if (@popCount(slot_bit) != 1) return self;
            const path = fifoPath(&self.path_buf, prefix, name, @ctz(slot_bit));
            self.path_len = path.len;
            if (mkfifo(path.ptr, 0o600) != 0 and std.posix.errno(-1) != .EXIST) return self;
            self.rfd = std.c.open(path.ptr, openFlags(.{ .ACCMODE = .RDONLY }));
            if (self.rfd == -1) {
                _ = std.c.unlink(path.ptr);
                return self;
            }
            self.wfd = std.c.open(path.ptr, openFlags(.{ .ACCMODE = .WRONLY }));
            self.valid = true;
            return self;
        }

        pub fn wait(self: *const @This(), timeout_ms: i32) bool {
            return pollReadable(self.rfd, timeout_ms);
        }

        pub fn drain(self: *const @This()) void {
            drainFd(self.rfd);
        }

        pub fn close(self: *@This()) void {
            if (!self.valid) return;
            if (self.wfd != -1) _ = std.c.close(self.wfd);
            _ = std.c.close(self.rfd);
            _ = std.c.unlink(self.path_buf[0..self.path_len :0]);
            self.* = .{};
        }
    };
};

test "the notify hash matches the golden" {
    try std.testing.expectEqualStrings("098e889ce378ae04", &notifyHash("", "xchan"));
}
