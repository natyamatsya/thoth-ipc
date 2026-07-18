#pragma once

#include <atomic>   // std::atomic<?>
#include <cstddef>  // offsetof (ABI offset accessors)
#include <limits>
#include <utility>
#include <type_traits>

#include "thoth-ipc/def.h"
#include "thoth-ipc/rw_lock.h"

#include "thoth-ipc/circ/elem_def.h"
#include "thoth-ipc/platform/detail.h"

namespace thoth {
namespace circ {

template <typename Policy,
          std::size_t DataSize,
          std::size_t AlignSize = (thoth::detail::min)(DataSize, alignof(std::max_align_t))>
class elem_array {
public:
    // The connection-management head is *composed*, not inherited: a base class
    // with data members would make elem_array non-standard-layout and forbid
    // offsetof on the ring-header fields. The ConnHead concept enforces the same
    // interface a base class used to (see the static_assert below).
    using conn_t   = thoth::circ::conn_head<Policy>;
    using policy_t = Policy;
    using cursor_t = decltype(std::declval<policy_t>().cursor());
    using elem_t   = typename policy_t::template elem_t<DataSize, AlignSize>;

    static_assert(thoth::circ::ConnHead<conn_t>,
                  "conn_head must satisfy the ConnHead connection-management contract");

    enum : std::size_t {
        // Byte offset of block_[0] = the ring header size (abi.json `ring_header`).
        // head_ (policy_t) is cache-line-aligned, so this is
        // align_up(sizeof(conn_t), alignof(policy_t)) + sizeof(policy_t) — NOT the
        // naive sizeof sum, which ignores that alignment padding.
        head_size  = thoth::make_align(alignof(policy_t), sizeof(conn_t)) + sizeof(policy_t),
        data_size  = DataSize,
        elem_max   = (std::numeric_limits<uint_t<8>>::max)() + 1, // default is 255 + 1
        elem_size  = sizeof(elem_t),
        block_size = elem_size * elem_max
    };

private:
    // conn_ is the first member, so the connection head sits at ring offset 0 (where
    // the inherited base used to) — the ring layout is byte-identical to cpp-ipc's.
    conn_t   conn_;
    policy_t head_;
    elem_t   block_[elem_max] {};

    /**
     * \remarks 'warning C4348: redefinition of default parameter' with MSVC.
     * \see
     *  - https://stackoverflow.com/questions/12656239/redefinition-of-default-template-parameter
     *  - https://developercommunity.visualstudio.com/content/problem/425978/incorrect-c4348-warning-in-nested-template-declara.html
    */
    template <typename P, bool/* = relat_trait<P>::is_multi_producer*/>
    struct sender_checker;

    template <typename P>
    struct sender_checker<P, true> {
        constexpr static bool connect() noexcept {
            // always return true
            return true;
        }
        constexpr static void disconnect() noexcept {}
    };

    template <typename P>
    struct sender_checker<P, false> {
        bool connect() noexcept {
            return !flag_.test_and_set(std::memory_order_acq_rel);
        }
        void disconnect() noexcept {
            flag_.clear();
        }

    private:
        // in shm, it should be 0 whether it's initialized or not.
        std::atomic_flag flag_ = ATOMIC_FLAG_INIT;
    };

    template <typename P, bool/* = relat_trait<P>::is_multi_consumer*/>
    struct receiver_checker;

    template <typename P>
    struct receiver_checker<P, true> {
        constexpr static cc_t connect(conn_t &conn) noexcept {
            return conn.connect();
        }
        constexpr static cc_t disconnect(conn_t &conn, cc_t cc_id) noexcept {
            return conn.disconnect(cc_id);
        }
    };

    template <typename P>
    struct receiver_checker<P, false> : protected sender_checker<P, false> {
        cc_t connect(conn_t &conn) noexcept {
            return sender_checker<P, false>::connect() ? conn.connect() : 0;
        }
        cc_t disconnect(conn_t &conn, cc_t cc_id) noexcept {
            sender_checker<P, false>::disconnect();
            return conn.disconnect(cc_id);
        }
    };

    sender_checker  <policy_t, relat_trait<policy_t>::is_multi_producer> s_ckr_;
    receiver_checker<policy_t, relat_trait<policy_t>::is_multi_consumer> r_ckr_;

public:
    // Connection-head interface, forwarded to the composed conn_ (was inherited).
    void init() { conn_.init(); }
    cc_t connections(std::memory_order order = std::memory_order_acquire) const noexcept {
        return conn_.connections(order);
    }
    bool connected(cc_t cc_id) const noexcept {
        return conn_.connected(cc_id);
    }
    std::size_t conn_count(std::memory_order order = std::memory_order_acquire) const noexcept {
        return conn_.conn_count(order);
    }

    bool connect_sender() noexcept {
        return s_ckr_.connect();
    }

    void disconnect_sender() noexcept {
        return s_ckr_.disconnect();
    }

    cc_t connect_receiver() noexcept {
        return r_ckr_.connect(conn_);
    }

    cc_t disconnect_receiver(cc_t cc_id) noexcept {
        return r_ckr_.disconnect(conn_, cc_id);
    }

    // ABI introspection: elem_array is standard-layout (conn_ composed, not a
    // base), so offsetof on its members is well-formed — the complete-class context
    // of these bodies also grants access to the private members. conn_ sits at the
    // ring start; head_ holds the policy cursor/epoch. ipc.cpp asserts these (plus
    // conn_head_base::*_offset() and the policy field offsets) against thoth::abi.
    static consteval std::size_t conn_offset() noexcept { return offsetof(elem_array, conn_); }
    static consteval std::size_t head_offset() noexcept { return offsetof(elem_array, head_); }

    cursor_t cursor() const noexcept {
        return head_.cursor();
    }

    template <typename Q, typename F>
    bool push(Q* que, F&& f) {
        return head_.push(que, std::forward<F>(f), block_);
    }

    template <typename Q, typename F>
    bool force_push(Q* que, F&& f) {
        return head_.force_push(que, std::forward<F>(f), block_);
    }

    template <typename Q, typename F, typename R>
    bool pop(Q* que, cursor_t* cur, F&& f, R&& out) {
        if (cur == nullptr) return false;
        return head_.pop(que, *cur, std::forward<F>(f), std::forward<R>(out), block_);
    }
};

} // namespace circ
} // namespace thoth
