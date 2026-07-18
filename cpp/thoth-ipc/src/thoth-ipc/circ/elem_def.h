#pragma once

#include <atomic>
#include <concepts> // std::same_as (ConnHead concept)
#include <cstddef>
#include <cstdint>
#include <new>

#include "thoth-ipc/def.h"
#include "thoth-ipc/rw_lock.h"

#include "thoth-ipc/platform/detail.h"

namespace thoth {
namespace circ {

using u1_t = thoth::uint_t<8>;
using u2_t = thoth::uint_t<32>;

/** only supports max 32 connections in broadcast mode */
using cc_t = u2_t;

constexpr u1_t index_of(u2_t c) noexcept {
    return static_cast<u1_t>(c);
}

class conn_head_base {
protected:
    std::atomic<cc_t> cc_{0}; // connections
    thoth::spin_lock lc_;
    std::atomic<bool> constructed_{false};

public:
    void init() {
        /* DCLP */
        if (!constructed_.load(std::memory_order_acquire)) {
            THOTH_IPC_UNUSED auto guard = thoth::detail::unique_lock(lc_);
            if (!constructed_.load(std::memory_order_relaxed)) {
                ::new (this) conn_head_base;
                constructed_.store(true, std::memory_order_release);
            }
        }
    }

    conn_head_base() = default;
    conn_head_base(conn_head_base const &) = delete;
    conn_head_base &operator=(conn_head_base const &) = delete;

    cc_t connections(std::memory_order order = std::memory_order_acquire) const noexcept {
        return this->cc_.load(order);
    }

    // ABI introspection: byte offsets of the ring-header fields this base
    // contributes (abi.json `ring_header`). conn_head_base is standard-layout, so
    // offsetof is well-formed, and the complete-class context of a member-function
    // body also grants access to the protected members. Consumed by ipc.cpp's ABI
    // conformance static_asserts — keeps the abi/ dependency out of this header.
    static consteval std::size_t cc_offset()          noexcept { return offsetof(conn_head_base, cc_); }
    static consteval std::size_t lc_offset()          noexcept { return offsetof(conn_head_base, lc_); }
    static consteval std::size_t constructed_offset() noexcept { return offsetof(conn_head_base, constructed_); }
};

template <typename P, bool = relat_trait<P>::is_broadcast>
class conn_head;

template <typename P>
class conn_head<P, true> : public conn_head_base {
public:
    cc_t connect() noexcept {
        for (unsigned k = 0;; thoth::yield(k)) {
            cc_t curr = this->cc_.load(std::memory_order_acquire);
            cc_t next = curr | (curr + 1); // find the first 0, and set it to 1.
            if (next == curr) {
                // connection-slot is full.
                return 0;
            }
            if (this->cc_.compare_exchange_weak(curr, next, std::memory_order_release)) {
                return next ^ curr; // return connected id
            }
        }
    }

    cc_t disconnect(cc_t cc_id) noexcept {
        return this->cc_.fetch_and(~cc_id, std::memory_order_acq_rel) & ~cc_id;
    }

    bool connected(cc_t cc_id) const noexcept {
        return (this->connections() & cc_id) != 0;
    }

    std::size_t conn_count(std::memory_order order = std::memory_order_acquire) const noexcept {
        cc_t cur = this->cc_.load(order);
        cc_t cnt; // accumulates the total bits set in cc
        for (cnt = 0; cur; ++cnt) cur &= cur - 1;
        return cnt;
    }
};

template <typename P>
class conn_head<P, false> : public conn_head_base {
public:
    cc_t connect() noexcept {
        return this->cc_.fetch_add(1, std::memory_order_relaxed) + 1;
    }

    cc_t disconnect(cc_t cc_id) noexcept {
        if (cc_id == ~static_cast<circ::cc_t>(0u)) {
            // clear all connections
            this->cc_.store(0, std::memory_order_relaxed);
            return 0u;
        }
        else {
            return this->cc_.fetch_sub(1, std::memory_order_relaxed) - 1;
        }
    }

    bool connected(cc_t cc_id) const noexcept {
        // In non-broadcast mode, connection tags are only used for counting.
        return (this->connections() != 0) && (cc_id != 0);
    }

    std::size_t conn_count(std::memory_order order = std::memory_order_acquire) const noexcept {
        return this->connections(order);
    }
};

// The connection-management contract elem_array requires of its head. cpp-ipc
// expressed this by having elem_array *inherit* conn_head — but a base class with
// data members makes the derived non-standard-layout, so the ring-header field
// offsets could not be offsetof-checked. Stating the same abstraction as a concept
// lets elem_array *compose* the head instead: it stays standard-layout (offsetof
// works) while the interface is still enforced at the composition site.
template <typename T>
concept ConnHead = requires(T h, T const ch, cc_t id) {
    { h.init() };
    { h.connect() }      -> std::same_as<cc_t>;
    { h.disconnect(id) } -> std::same_as<cc_t>;
    { ch.connections() } -> std::same_as<cc_t>;
    { ch.connected(id) } -> std::same_as<bool>;
    { ch.conn_count() }  -> std::same_as<std::size_t>;
};

} // namespace circ
} // namespace thoth
