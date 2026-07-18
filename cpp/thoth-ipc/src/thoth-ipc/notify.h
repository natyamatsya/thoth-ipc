#pragma once

// Layer 1 of the optional stdexec async-receive work (RFC:
// context/stdexec-async-recv-rfc.md): a per-receiver "notify handle" that turns
// a channel's readiness into a waitable, multiplexable kernel object with a file
// descriptor, so a consumer can select/epoll/kqueue on it instead of dedicating
// a blocking thread per channel.
//
// Everything here is gated on THOTH_IPC_NOTIFY_FD and is ZERO COST when the gate is
// off: the objects hold no resources and the send hot path performs no extra
// syscalls (the members below become empty and the seam calls compile away).
//
// Cross-process model
// -------------------
// libipc synchronises writer and reader *across processes* through shm-backed
// futex/ulock conditions (thoth::detail::waiter). A plain self-pipe/eventfd is
// process-local and cannot carry the remote writer's enqueue signal into the
// reader's process. Two cross-process, fd-bearing, kqueue/epoll-able backends:
//
//   * macOS  -> libnotify (<notify.h>): notify_post(name) wakes an fd obtained
//     from notify_register_file_descriptor(name, ...) in ANY process. It is the
//     native Darwin notification service, and it is *multicast* — one post wakes
//     every registered reader — so a single name per channel honours route (1->N)
//     and channel (N->N) broadcast directly. This is the default on Apple.
//
//   * POSIX  -> named FIFO (mkfifo): portable fallback (Linux, or Apple with
//     THOTH_IPC_NOTIFY_FIFO). A FIFO is point-to-point, so broadcast is honoured by
//     giving each reader connection slot its own FIFO: a receiver owns the FIFO
//     for its slot, and a sender pokes every connected slot on enqueue.

#include "thoth-ipc/imp/detect_plat.h"

#if defined(THOTH_IPC_NOTIFY_FD)

// Backend selection: named auto-reset Events on Windows; libnotify on Apple by
// default; POSIX FIFO elsewhere (and on Apple when THOTH_IPC_NOTIFY_FIFO forces the
// portable path).
#if defined(THOTH_IPC_OS_WIN)
#  define THOTH_IPC_NOTIFY_BACKEND_WINEVENT 1
#elif defined(THOTH_IPC_OS_APPLE) && !defined(THOTH_IPC_NOTIFY_FIFO)
#  define THOTH_IPC_NOTIFY_BACKEND_LIBNOTIFY 1
#else
#  define THOTH_IPC_NOTIFY_BACKEND_FIFO 1
#endif

#if !defined(THOTH_IPC_NOTIFY_BACKEND_WINEVENT)
#include <fcntl.h>
#include <unistd.h>
#endif

#include <cerrno>
#include <cstdint>
#include <string>

#include "thoth-ipc/circ/elem_def.h"                 // thoth::circ::cc_t
#include "thoth-ipc/mem/resource.h"                  // thoth::make_public_abi_prefix
#include "thoth-ipc/platform/posix/shm_name.h"       // fnv1a_64 / to_hex

namespace thoth {
namespace detail {

// Short, filesystem-/service-safe identity for a channel: a 16-hex FNV-1a hash
// of the (possibly long, prefixed) channel name.
inline std::string notify_hash(std::string const &prefix, std::string const &name) {
    std::string id = thoth::make_public_abi_prefix(prefix, "NOTIFY__", name);
    char hex[16];
    thoth::posix_::detail::to_hex(
        thoth::posix_::detail::fnv1a_64(id.data(), id.size()), hex);
    return std::string(hex, 16);
}

} // namespace detail
} // namespace thoth

// =============================================================================
#if defined(THOTH_IPC_NOTIFY_BACKEND_WINEVENT)
// =============================================================================

#include <intrin.h> // _BitScanForward
#include "thoth-ipc/imp/log.h"                // THOTH_IPC_LOG (used by get_sa.h)
#include "thoth-ipc/platform/win/to_tchar.h" // to_tchar + win_object_name (+ <Windows.h>)
#include "thoth-ipc/platform/win/get_sa.h"   // detail::get_sa (SECURITY_ATTRIBUTES)

namespace thoth {
namespace detail {

// Max reader connection slots in broadcast mode (see circ::conn_head).
inline constexpr int notify_max_slots = 32;

// Bit position (0..31) of a single-bit connection id, or -1 if none.
inline int notify_slot_of(thoth::circ::cc_t bit) noexcept {
    if (bit == 0) return -1;
    unsigned long idx = 0;
    _BitScanForward(&idx, static_cast<unsigned long>(bit));
    return static_cast<int>(idx);
}

// Deterministic, cross-process AND cross-language event name:
//   <ns>ipcntf_<16-hex hash>_<slot>
// where <ns> is the Windows object namespace prefix (default Local\, via
// win_object_name). Byte-exact with the Rust WINEVENT backend. Returns a TCHAR
// string (narrow or wide per the build's UNICODE setting) for ::CreateEvent /
// ::OpenEvent; ASCII names map to the same kernel object either way.
inline auto notify_event_name(std::string const &prefix,
                              std::string const &name, int slot) {
    std::string id = "ipcntf_" + notify_hash(prefix, name) + "_" + std::to_string(slot);
    return to_tchar(win_object_name(id));
}

// Reader side: owns the auto-reset Event for this receiver's connection slot.
class notify_sink {
    HANDLE ev_ = nullptr;

public:
    notify_sink() = default;
    notify_sink(notify_sink const &) = delete;
    notify_sink &operator=(notify_sink const &) = delete;
    ~notify_sink() { close(); }

    bool valid() const noexcept { return ev_ != nullptr; }
    HANDLE native_handle() const noexcept { return ev_; }

    bool open(std::string const &prefix, std::string const &name,
              thoth::circ::cc_t slot_bit) {
        if (ev_ != nullptr) return true;
        int slot = notify_slot_of(slot_bit);
        if (slot < 0 || slot >= notify_max_slots) return false;
        auto en = notify_event_name(prefix, name, slot);
        // Auto-reset (manual reset FALSE), initially non-signaled. CreateEvent
        // opens the existing object if a sender created it first (idempotent).
        ev_ = ::CreateEvent(detail::get_sa(), FALSE, FALSE, en.c_str());
        return ev_ != nullptr;
    }

    // No-op: an auto-reset event self-resets when a wait wakes on it.
    void drain() noexcept {}

    void close() noexcept {
        if (ev_ != nullptr) { ::CloseHandle(ev_); ev_ = nullptr; }
    }
};

// Writer side: on enqueue, SetEvent every connected reader slot's Event (skip
// our own). SetEvent on an already-signaled auto-reset event is idempotent —
// it stays signaled, the level-triggered behaviour the fd backends have.
class notify_source {
    HANDLE ev_[notify_max_slots];

    void close_slot(int i) noexcept {
        if (ev_[i] != nullptr) { ::CloseHandle(ev_[i]); ev_[i] = nullptr; }
    }

public:
    notify_source() { for (int i = 0; i < notify_max_slots; ++i) ev_[i] = nullptr; }
    notify_source(notify_source const &) = delete;
    notify_source &operator=(notify_source const &) = delete;
    ~notify_source() { close(); }

    void signal(std::string const &prefix, std::string const &name,
                thoth::circ::cc_t conns, thoth::circ::cc_t self) noexcept {
        for (int i = 0; i < notify_max_slots; ++i) {
            thoth::circ::cc_t bit = static_cast<thoth::circ::cc_t>(1u) << i;
            bool want = (conns & bit) && !(self & bit);
            if (!want) { close_slot(i); continue; }
            if (ev_[i] == nullptr) {
                auto en = notify_event_name(prefix, name, i);
                // Open the reader's event; if it doesn't exist yet, create it
                // (auto-reset) so a sender-first race still lands a token.
                ev_[i] = ::OpenEvent(EVENT_MODIFY_STATE, FALSE, en.c_str());
                if (ev_[i] == nullptr) {
                    ev_[i] = ::CreateEvent(detail::get_sa(), FALSE, FALSE, en.c_str());
                }
                if (ev_[i] == nullptr) continue; // reader vanished; retry next time
            }
            ::SetEvent(ev_[i]);
        }
    }

    void close() noexcept {
        for (int i = 0; i < notify_max_slots; ++i) close_slot(i);
    }
};

// Events are refcounted kernel objects freed when the last handle closes —
// nothing on disk to reclaim.
inline void notify_clear_storage(std::string const &, std::string const &) noexcept {}
inline void notify_clear_slot(std::string const &, std::string const &,
                              thoth::circ::cc_t /*slot_bit*/) noexcept {}

} // namespace detail
} // namespace thoth

// =============================================================================
#elif defined(THOTH_IPC_NOTIFY_BACKEND_LIBNOTIFY)
// =============================================================================

#include <notify.h>

namespace thoth {
namespace detail {

// libnotify service key for a channel (one per channel — posts are multicast).
inline std::string notify_key(std::string const &prefix, std::string const &name) {
    return "ipc.ntf." + notify_hash(prefix, name);
}

// Reader side: an fd that libnotify writes a token to on every matching post.
class notify_sink {
    int fd_    = -1;
    int token_ = -1;

public:
    notify_sink() = default;
    notify_sink(notify_sink const &) = delete;
    notify_sink &operator=(notify_sink const &) = delete;
    ~notify_sink() { close(); }

    bool valid() const noexcept { return fd_ != -1; }
    int native_handle() const noexcept { return fd_; }

    // slot_bit is unused: libnotify is multicast, one name per channel.
    bool open(std::string const &prefix, std::string const &name,
              thoth::circ::cc_t /*slot_bit*/) {
        if (fd_ != -1) return true;
        std::string key = notify_key(prefix, name);
        int fd = -1, tok = -1;
        if (::notify_register_file_descriptor(key.c_str(), &fd, 0, &tok)
                != NOTIFY_STATUS_OK) {
            return false;
        }
        // Non-blocking so drain() never stalls; cloexec for fd hygiene.
        int fl = ::fcntl(fd, F_GETFL, 0);
        if (fl != -1) ::fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        ::fcntl(fd, F_SETFD, FD_CLOEXEC);
        fd_ = fd;
        token_ = tok;
        return true;
    }

    // Consume the pending token ints after the fd signalled readable.
    void drain() noexcept {
        if (fd_ == -1) return;
        int tok;
        while (::read(fd_, &tok, sizeof(tok)) > 0) { /* discard */ }
    }

    void close() noexcept {
        // notify_cancel closes the fd once its last token is cancelled.
        if (token_ != -1) { ::notify_cancel(token_); token_ = -1; }
        fd_ = -1;
    }
};

// Writer side: post the channel's name; libnotify multicasts to all readers.
class notify_source {
    std::string key_; // cached (prefix/name are stable per channel)

public:
    void signal(std::string const &prefix, std::string const &name,
                thoth::circ::cc_t /*conns*/, thoth::circ::cc_t /*self*/) noexcept {
        if (key_.empty()) key_ = notify_key(prefix, name);
        ::notify_post(key_.c_str());
    }
    void close() noexcept {}
};

// No filesystem node to reclaim for libnotify.
inline void notify_clear_storage(std::string const &, std::string const &) noexcept {}
// Per-slot reclamation (dead-connection reaper): nothing to do for libnotify.
inline void notify_clear_slot(std::string const &, std::string const &,
                              thoth::circ::cc_t /*slot_bit*/) noexcept {}

} // namespace detail
} // namespace thoth

// =============================================================================
#else // THOTH_IPC_NOTIFY_BACKEND_FIFO
// =============================================================================

#include <sys/stat.h>
#include <sys/types.h>
#include <cstdlib>

#if !defined(THOTH_IPC_OS_APPLE)
#  include <csignal>
#endif

namespace thoth {
namespace detail {

// Max reader connection slots in broadcast mode (see circ::conn_head).
inline constexpr int notify_max_slots = 32;

// Bit position (0..31) of a single-bit connection id, or -1 if none.
inline int notify_slot_of(thoth::circ::cc_t bit) noexcept {
    return (bit == 0) ? -1 : __builtin_ctz(static_cast<unsigned>(bit));
}

// Deterministic FIFO path shared by both processes: <dir>/ipcntf_<hash>.<slot>.
// Directory is /tmp by default (a path both peers agree on), overridable via
// THOTH_IPC_NOTIFY_DIR for sandboxed/multi-user setups.
inline std::string notify_fifo_path(std::string const &prefix,
                                    std::string const &name, int slot) {
    char const *dir = std::getenv("THOTH_IPC_NOTIFY_DIR");
    std::string base = (dir != nullptr && dir[0] != '\0') ? dir : "/tmp";
    std::string out;
    out.reserve(base.size() + 32);
    out.append(base).append("/ipcntf_").append(notify_hash(prefix, name));
    out.push_back('.');
    out.append(std::to_string(slot));
    return out;
}

// Suppress SIGPIPE for a write to a FIFO whose reader vanished; we want EPIPE,
// never the signal. macOS has a per-fd flag; elsewhere block it on this thread.
#if defined(THOTH_IPC_OS_APPLE)
inline void notify_set_nosigpipe(int fd) noexcept { ::fcntl(fd, F_SETNOSIGPIPE, 1); }
struct notify_sigpipe_guard { notify_sigpipe_guard() noexcept {} };
#else
inline void notify_set_nosigpipe(int) noexcept {}
struct notify_sigpipe_guard {
    sigset_t old_{};
    bool blocked_ = false;
    notify_sigpipe_guard() noexcept {
        sigset_t s; sigemptyset(&s); sigaddset(&s, SIGPIPE);
        blocked_ = (pthread_sigmask(SIG_BLOCK, &s, &old_) == 0);
    }
    ~notify_sigpipe_guard() noexcept {
        sigset_t pend;
        if (sigpending(&pend) == 0 && sigismember(&pend, SIGPIPE)) {
            sigset_t only; sigemptyset(&only); sigaddset(&only, SIGPIPE);
            int sig; struct timespec zero{0, 0};
            ::sigtimedwait(&only, &sig, &zero);
        }
        if (blocked_) pthread_sigmask(SIG_SETMASK, &old_, nullptr);
    }
};
#endif

// Reader side: owns the FIFO for this receiver's connection slot.
class notify_sink {
    int rfd_ = -1;   // read end, handed out via native_handle()
    int wfd_ = -1;   // our own write end, kept open so the FIFO never reports EOF
    std::string path_;

public:
    notify_sink() = default;
    notify_sink(notify_sink const &) = delete;
    notify_sink &operator=(notify_sink const &) = delete;
    ~notify_sink() { close(); }

    bool valid() const noexcept { return rfd_ != -1; }
    int native_handle() const noexcept { return rfd_; }

    bool open(std::string const &prefix, std::string const &name,
              thoth::circ::cc_t slot_bit) {
        if (rfd_ != -1) return true;
        int slot = notify_slot_of(slot_bit);
        if (slot < 0 || slot >= notify_max_slots) return false;
        path_ = notify_fifo_path(prefix, name, slot);
        if (::mkfifo(path_.c_str(), 0600) != 0 && errno != EEXIST) {
            path_.clear();
            return false;
        }
        rfd_ = ::open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (rfd_ == -1) { ::unlink(path_.c_str()); path_.clear(); return false; }
        wfd_ = ::open(path_.c_str(), O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        return true;
    }

    void drain() noexcept {
        if (rfd_ == -1) return;
        char buf[256];
        while (::read(rfd_, buf, sizeof(buf)) > 0) { /* discard */ }
    }

    void close() noexcept {
        if (wfd_ != -1) { ::close(wfd_); wfd_ = -1; }
        if (rfd_ != -1) { ::close(rfd_); rfd_ = -1; }
        if (!path_.empty()) { ::unlink(path_.c_str()); path_.clear(); }
    }
};

// Writer side: on enqueue, poke every connected reader slot's FIFO.
class notify_source {
    int wfd_[notify_max_slots];

    void close_slot(int i) noexcept {
        if (wfd_[i] != -1) { ::close(wfd_[i]); wfd_[i] = -1; }
    }

public:
    notify_source() { for (int i = 0; i < notify_max_slots; ++i) wfd_[i] = -1; }
    notify_source(notify_source const &) = delete;
    notify_source &operator=(notify_source const &) = delete;
    ~notify_source() { close(); }

    void signal(std::string const &prefix, std::string const &name,
                thoth::circ::cc_t conns, thoth::circ::cc_t self) noexcept {
        for (int i = 0; i < notify_max_slots; ++i) {
            thoth::circ::cc_t bit = static_cast<thoth::circ::cc_t>(1u) << i;
            bool want = (conns & bit) && !(self & bit);
            if (!want) { close_slot(i); continue; }
            if (wfd_[i] == -1) {
                std::string p = notify_fifo_path(prefix, name, i);
                wfd_[i] = ::open(p.c_str(), O_WRONLY | O_NONBLOCK | O_CLOEXEC);
                if (wfd_[i] == -1) continue; // ENXIO: reader just vanished
                notify_set_nosigpipe(wfd_[i]);
            }
            char one = 1;
            notify_sigpipe_guard sg;
            ssize_t n = ::write(wfd_[i], &one, 1);
            if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                close_slot(i); // EPIPE/ENXIO: reader gone -> reopen next time
            }
            // EAGAIN: an unconsumed wake byte remains -> readiness still holds.
        }
    }

    void close() noexcept {
        for (int i = 0; i < notify_max_slots; ++i) close_slot(i);
    }
};

// Best-effort removal of every slot FIFO for a channel.
inline void notify_clear_storage(std::string const &prefix,
                                 std::string const &name) noexcept {
    for (int i = 0; i < notify_max_slots; ++i) {
        ::unlink(notify_fifo_path(prefix, name, i).c_str());
    }
}

// Reclaim a single reaped slot's FIFO node (dead-connection reaper).
inline void notify_clear_slot(std::string const &prefix, std::string const &name,
                              thoth::circ::cc_t slot_bit) noexcept {
    int slot = notify_slot_of(slot_bit);
    if (slot >= 0 && slot < notify_max_slots) {
        ::unlink(notify_fifo_path(prefix, name, slot).c_str());
    }
}

} // namespace detail
} // namespace thoth

#endif // backend selection

#endif // THOTH_IPC_NOTIFY_FD
