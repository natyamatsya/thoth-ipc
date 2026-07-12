#pragma once

// Dead-connection reaping for broadcast routes (RFC:
// context/dead-connection-reaper-rfc.md), Phase 1.
//
// A broadcast route tracks receivers as a 32-bit atomic bitmask (conn_head_base::
// cc_). A SIGKILLed peer never clears its bit — a *phantom* — which stalls ring
// reclamation, exhausts the 32 slots, and inflates recv_count. This adds a
// per-slot owner table (one PID per cc_ bit) in a dedicated LV_CONN__ segment and
// a PID-liveness reaper that clears bits whose owner process is gone.
//
// Design notes:
//   * The table lives in its OWN shm segment, never overlaid on the byte-exact
//     ring/waiter segments (see context/xlang-channel-abi.md).
//   * Lock-free: a fresh connect writes its owner *after* claiming the bit, and
//     the reaper CAS-clears the owner only if it is still the dead PID it saw —
//     so a slot reused by a live newcomer is never evicted. A set bit whose owner
//     is still 0 (mid-connect, or a port that does not populate the table) is
//     skipped — safe degradation, never a false reap.
//   * Phase 1 clears the cc_ bit (fixes the count, the 32-cap, and future
//     pushes). In-flight ring elements are freed by force_push's epoch bump as
//     today; wiring the reaper into force_push is Phase 2.

#include <atomic>
#include <cstdint>

#include "libipc/imp/detect_plat.h"
#include "libipc/circ/elem_def.h" // ipc::circ::cc_t

#if defined(LIBIPC_OS_WIN)
#  include <process.h>
#else
#  include <csignal>
#  include <cerrno>
#  include <unistd.h>
#endif

namespace ipc {
namespace detail {

// One owner record per cc_ bit. **Byte-exact cross-language layout** (Phase 4 /
// xlang §9): pid @0 (int32), start_tok @8 (uint64, reserved for PID-reuse
// hardening in Phase 3 — written as 0 here). sizeof == 16.
struct slot_owner {
    std::atomic<std::int32_t>  pid{0};       // @0  0 == free
    std::atomic<std::uint64_t> start_tok{0}; // @8  reserved (Phase 3)
};
static_assert(sizeof(slot_owner) == 16, "slot_owner must be 16 bytes (xlang ABI)");
static_assert(alignof(slot_owner) == 8, "slot_owner must be 8-aligned (xlang ABI)");

// The LV_CONN__ segment: one slot_owner per broadcast connection bit (max 32).
struct conn_liveness {
    slot_owner slots[32];
};
static_assert(sizeof(conn_liveness) == 512, "conn_liveness must be 512 bytes (xlang ABI)");

// Bit position (0..31) of a single-bit connection id.
inline int slot_index(ipc::circ::cc_t bit) noexcept {
#if defined(_MSC_VER)
    unsigned long i = 0;
    _BitScanForward(&i, static_cast<unsigned long>(bit));
    return static_cast<int>(i);
#else
    return __builtin_ctz(static_cast<unsigned>(bit));
#endif
}

// This process's identity.
inline std::int32_t self_pid() noexcept {
#if defined(LIBIPC_OS_WIN)
    return static_cast<std::int32_t>(::_getpid());
#else
    return static_cast<std::int32_t>(::getpid());
#endif
}

// Is `pid` a live process? `kill(pid, 0)` is definitive on POSIX and NEVER
// reports a live process as dead (EPERM ⇒ exists). Windows reaping is a TODO
// (Phase 3+): report alive so nothing is falsely reaped.
inline bool is_process_alive(std::int32_t pid) noexcept {
#if defined(LIBIPC_OS_WIN)
    return true; // TODO: OpenProcess + GetExitCodeProcess
#else
    if (pid <= 0) return false;
    return (::kill(static_cast<pid_t>(pid), 0) == 0) || (errno != ESRCH);
#endif
}

// Record ownership of a freshly connected slot. Call *after* the cc_ bit is set,
// so the reaper's "owner still 0 ⇒ skip" window is the only race, and it is safe.
inline void liveness_set_owner(conn_liveness *lv, ipc::circ::cc_t bit) noexcept {
    if (lv == nullptr || bit == 0) return;
    int idx = slot_index(bit);
    lv->slots[idx].start_tok.store(0, std::memory_order_relaxed);
    lv->slots[idx].pid.store(self_pid(), std::memory_order_release);
}

// Release ownership of a slot on clean disconnect.
inline void liveness_clear_owner(conn_liveness *lv, ipc::circ::cc_t bit) noexcept {
    if (lv == nullptr || bit == 0) return;
    int idx = slot_index(bit);
    lv->slots[idx].pid.store(0, std::memory_order_release);
    lv->slots[idx].start_tok.store(0, std::memory_order_relaxed);
}

// Reap dead receivers from `live` (the current cc_ mask). For each set bit whose
// recorded owner PID is gone, CAS-claim the owner (dead → 0) and, on success,
// clear the bit via `disconnect_bit(bit)` and reclaim its readiness FIFO via
// `notify_clear(bit)`. Returns the reaped mask. Callable by any participant.
template <typename DisconnectFn, typename NotifyFn>
inline ipc::circ::cc_t reap_dead_receivers(conn_liveness *lv, ipc::circ::cc_t live,
                                           DisconnectFn &&disconnect_bit,
                                           NotifyFn &&notify_clear) noexcept {
    if (lv == nullptr) return 0;
    ipc::circ::cc_t reaped = 0;
    for (ipc::circ::cc_t m = live; m != 0; m &= (m - 1)) {
        ipc::circ::cc_t bit = m & static_cast<ipc::circ::cc_t>(~m + 1); // lowest set bit
        int idx = slot_index(bit);
        std::int32_t p = lv->slots[idx].pid.load(std::memory_order_acquire);
        if (p == 0 || is_process_alive(p)) {
            continue; // unknown owner (skip, never false-reap) or still alive
        }
        std::int32_t expected = p;
        // Only reap if the owner is still the dead PID we saw — a slot reused by a
        // live newcomer would have overwritten it, so we leave the newcomer be.
        if (lv->slots[idx].pid.compare_exchange_strong(
                expected, 0, std::memory_order_acq_rel)) {
            disconnect_bit(bit);
            notify_clear(bit);
            reaped |= bit;
        }
    }
    return reaped;
}

} // namespace detail
} // namespace ipc
