// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <os/lock.h>

namespace ipc {
namespace detail {
namespace sync {

// Lightweight process-local lock using macOS os_unfair_lock.
// 4 bytes, no allocation, no syscall on uncontended path.
// NOT suitable for cross-process use (process-local only).
class spin_lock {
    os_unfair_lock lock_ = OS_UNFAIR_LOCK_INIT;

public:
    spin_lock() = default;
    ~spin_lock() = default;

    spin_lock(const spin_lock &) = delete;
    spin_lock &operator=(const spin_lock &) = delete;

    void lock() noexcept {
        os_unfair_lock_lock(&lock_);
    }

    bool try_lock() noexcept {
        return os_unfair_lock_trylock(&lock_);
    }

    void unlock() noexcept {
        os_unfair_lock_unlock(&lock_);
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
