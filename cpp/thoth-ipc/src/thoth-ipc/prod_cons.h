#pragma once

#include <atomic>
#include <utility>
#include <cstring>
#include <cstdint>

#include "thoth-ipc/def.h"

#include "thoth-ipc/platform/detail.h"
#include "thoth-ipc/circ/elem_def.h"
#include "thoth-ipc/imp/log.h"
#include "thoth-ipc/utility/utility.h"

namespace thoth {

////////////////////////////////////////////////////////////////
/// producer-consumer implementation
////////////////////////////////////////////////////////////////

template <typename Flag>
struct prod_cons_impl;

namespace detail_pc {

// Elements per ring: a cursor addresses its element modulo this (circ::index_of).
constexpr circ::u2_t ring_lap = static_cast<circ::u2_t>((std::numeric_limits<circ::u1_t>::max)()) + 1;

// Of the broadcast receivers `bits` still marked on the element a writer is
// about to reuse, those that really have yet to read it: the element held
// position `pos`, and a mark from before its receiver started is a previous
// owner's leftover (thoth::detail::liveness_live_marks). Wrappers without a
// liveness table count every mark.
template <typename W>
circ::cc_t live_marks(W* wrapper, circ::cc_t bits, circ::u2_t pos) noexcept {
    if constexpr (requires { wrapper->live_marks(bits, pos); }) {
        return wrapper->live_marks(bits, pos);
    } else {
        return bits;
    }
}

} // namespace detail_pc

template <>
struct prod_cons_impl<wr<relat::single, relat::single, trans::unicast>> {

    template <std::size_t DataSize, std::size_t AlignSize>
    struct elem_t {
        alignas(AlignSize) byte_t data_[DataSize] {};
    };

    alignas(cache_line_size) std::atomic<circ::u2_t> rd_; // read index
    alignas(cache_line_size) std::atomic<circ::u2_t> wt_; // write index

    constexpr circ::u2_t cursor() const noexcept {
        return 0;
    }

    template <typename W, typename F, typename E>
    bool push(W* /*wrapper*/, F&& f, E* elems) {
        auto cur_wt = circ::index_of(wt_.load(std::memory_order_relaxed));
        if (cur_wt == circ::index_of(rd_.load(std::memory_order_acquire) - 1)) {
            return false; // full
        }
        std::forward<F>(f)(&(elems[cur_wt].data_));
        wt_.fetch_add(1, std::memory_order_release);
        return true;
    }

    /**
     * In single-single-unicast, 'force_push' means 'no reader' or 'the only one reader is dead'.
     * So we could just disconnect all connections of receiver, and return false.
    */
    template <typename W, typename F, typename E>
    bool force_push(W* wrapper, F&&, E*) {
        wrapper->elems()->disconnect_receiver(~static_cast<circ::cc_t>(0u));
        return false;
    }

    template <typename W, typename F, typename R, typename E>
    bool pop(W* /*wrapper*/, circ::u2_t& /*cur*/, F&& f, R&& out, E* elems) {
        auto cur_rd = circ::index_of(rd_.load(std::memory_order_relaxed));
        if (cur_rd == circ::index_of(wt_.load(std::memory_order_acquire))) {
            return false; // empty
        }
        std::forward<F>(f)(&(elems[cur_rd].data_));
        std::forward<R>(out)(true);
        rd_.fetch_add(1, std::memory_order_release);
        return true;
    }
};

template <>
struct prod_cons_impl<wr<relat::single, relat::multi , trans::unicast>>
     : prod_cons_impl<wr<relat::single, relat::single, trans::unicast>> {

    template <typename W, typename F, typename E>
    bool force_push(W* wrapper, F&&, E*) {
        wrapper->elems()->disconnect_receiver(1);
        return false;
    }

    template <typename W, typename F, typename R, 
              template <std::size_t, std::size_t> class E, std::size_t DS, std::size_t AS>
    bool pop(W* /*wrapper*/, circ::u2_t& /*cur*/, F&& f, R&& out, E<DS, AS>* elems) {
        byte_t buff[DS];
        for (unsigned k = 0;;) {
            auto cur_rd = rd_.load(std::memory_order_relaxed);
            if (circ::index_of(cur_rd) ==
                circ::index_of(wt_.load(std::memory_order_acquire))) {
                return false; // empty
            }
            std::memcpy(buff, &(elems[circ::index_of(cur_rd)].data_), sizeof(buff));
            if (rd_.compare_exchange_weak(cur_rd, cur_rd + 1, std::memory_order_release)) {
                std::forward<F>(f)(buff);
                std::forward<R>(out)(true);
                return true;
            }
            thoth::yield(k);
        }
    }
};

template <>
struct prod_cons_impl<wr<relat::multi , relat::multi, trans::unicast>>
     : prod_cons_impl<wr<relat::single, relat::multi, trans::unicast>> {

    using flag_t = std::uint64_t;

    template <std::size_t DataSize, std::size_t AlignSize>
    struct elem_t {
        alignas(AlignSize) byte_t data_[DataSize] {};
        std::atomic<flag_t> f_ct_ { 0 }; // commit flag
    };

    alignas(cache_line_size) std::atomic<circ::u2_t> ct_; // commit index

    template <typename W, typename F, typename E>
    bool push(W* /*wrapper*/, F&& f, E* elems) {
        circ::u2_t cur_ct, nxt_ct;
        for (unsigned k = 0;;) {
            cur_ct = ct_.load(std::memory_order_relaxed);
            if (circ::index_of(nxt_ct = cur_ct + 1) ==
                circ::index_of(rd_.load(std::memory_order_acquire))) {
                return false; // full
            }
            if (ct_.compare_exchange_weak(cur_ct, nxt_ct, std::memory_order_acq_rel)) {
                break;
            }
            thoth::yield(k);
        }
        auto* el = elems + circ::index_of(cur_ct);
        std::forward<F>(f)(&(el->data_));
        // set flag & try update wt
        el->f_ct_.store(~static_cast<flag_t>(cur_ct), std::memory_order_release);
        while (1) {
            auto cac_ct = el->f_ct_.load(std::memory_order_acquire);
            if (cur_ct != wt_.load(std::memory_order_relaxed)) {
                return true;
            }
            if ((~cac_ct) != cur_ct) {
                return true;
            }
            if (!el->f_ct_.compare_exchange_strong(cac_ct, 0, std::memory_order_relaxed)) {
                return true;
            }
            wt_.store(nxt_ct, std::memory_order_release);
            cur_ct = nxt_ct;
            nxt_ct = cur_ct + 1;
            el = elems + circ::index_of(cur_ct);
        }
        return true;
    }

    template <typename W, typename F, typename E>
    bool force_push(W* wrapper, F&&, E*) {
        wrapper->elems()->disconnect_receiver(1);
        return false;
    }

    template <typename W, typename F, typename R, 
              template <std::size_t, std::size_t> class E, std::size_t DS, std::size_t AS>
    bool pop(W* /*wrapper*/, circ::u2_t& /*cur*/, F&& f, R&& out, E<DS, AS>* elems) {
        byte_t buff[DS];
        for (unsigned k = 0;;) {
            auto cur_rd = rd_.load(std::memory_order_relaxed);
            auto cur_wt = wt_.load(std::memory_order_acquire);
            auto id_rd  = circ::index_of(cur_rd);
            auto id_wt  = circ::index_of(cur_wt);
            if (id_rd == id_wt) {
                auto* el = elems + id_wt;
                auto cac_ct = el->f_ct_.load(std::memory_order_acquire);
                if ((~cac_ct) != cur_wt) {
                    return false; // empty
                }
                if (el->f_ct_.compare_exchange_weak(cac_ct, 0, std::memory_order_relaxed)) {
                    wt_.store(cur_wt + 1, std::memory_order_release);
                }
                k = 0;
            }
            else {
                std::memcpy(buff, &(elems[circ::index_of(cur_rd)].data_), sizeof(buff));
                if (rd_.compare_exchange_weak(cur_rd, cur_rd + 1, std::memory_order_release)) {
                    std::forward<F>(f)(buff);
                    std::forward<R>(out)(true);
                    return true;
                }
                thoth::yield(k);
            }
        }
    }
};

template <>
struct prod_cons_impl<wr<relat::single, relat::multi, trans::broadcast>> {

    using rc_t = std::uint64_t;

    enum : rc_t {
        ep_mask = 0x00000000ffffffffull,
        ep_incr = 0x0000000100000000ull
    };

    template <std::size_t DataSize, std::size_t AlignSize>
    struct elem_t {
        alignas(AlignSize) byte_t data_[DataSize] {};
        std::atomic<rc_t> rc_ { 0 }; // read-counter
    };

    alignas(cache_line_size) std::atomic<circ::u2_t> wt_;   // write index
    alignas(cache_line_size) rc_t epoch_ { 0 };             // only one writer

    circ::u2_t cursor() const noexcept {
        return wt_.load(std::memory_order_acquire);
    }

    template <typename W, typename F, typename E>
    bool push(W* wrapper, F&& f, E* elems) {
        E* el;
        for (unsigned k = 0;;) {
            circ::cc_t cc = wrapper->elems()->connections(std::memory_order_relaxed);
            if (cc == 0) return false; // no reader
            circ::u2_t wt = wt_.load(std::memory_order_relaxed);
            el = elems + circ::index_of(wt);
            // check all consumers have finished reading this element
            auto cur_rc = el->rc_.load(std::memory_order_acquire);
            circ::cc_t rem_cc = cur_rc & ep_mask;
            if ((cc & rem_cc) && ((cur_rc & ~ep_mask) == epoch_) &&
                detail_pc::live_marks(wrapper, cc & rem_cc, wt - detail_pc::ring_lap)) {
                return false; // has not finished yet
            }
            // consider rem_cc to be 0 here
            if (el->rc_.compare_exchange_weak(
                        cur_rc, epoch_ | static_cast<rc_t>(cc), std::memory_order_release)) {
                break;
            }
            thoth::yield(k);
        }
        std::forward<F>(f)(&(el->data_));
        wt_.fetch_add(1, std::memory_order_release);
        return true;
    }

    template <typename W, typename F, typename E>
    bool force_push(W* wrapper, F&& f, E* elems) {
        THOTH_IPC_LOG();
        E* el;
        epoch_ += ep_incr;
        for (unsigned k = 0;;) {
            circ::cc_t cc = wrapper->elems()->connections(std::memory_order_relaxed);
            if (cc == 0) return false; // no reader
            circ::u2_t wt = wt_.load(std::memory_order_relaxed);
            el = elems + circ::index_of(wt);
            // check all consumers have finished reading this element (a previous
            // owner's leftover mark is not a wedged reader: do not disconnect it)
            auto cur_rc = el->rc_.load(std::memory_order_acquire);
            circ::cc_t rem_cc = detail_pc::live_marks(wrapper, cur_rc & ep_mask & cc, wt - detail_pc::ring_lap);
            if (cc & rem_cc) {
                log.debug("force_push: k = ", k, ", cc = ", cc, ", rem_cc = ", rem_cc);
                // Reap only the readers on this stuck element whose owner process
                // has died (dead-connection reaper, Phase 2). Keeps live-but-slow
                // readers connected instead of the old blanket disconnect.
                circ::cc_t before = cc;
                cc = wrapper->reap_dead(cc & rem_cc);
                if (cc == before) {
                    // Nothing dead — a genuinely live-but-wedged reader is holding
                    // the ring. Fall back to disconnecting them so we cannot deadlock.
                    cc = wrapper->elems()->disconnect_receiver(rem_cc);
                }
                if (cc == 0) return false; // no reader
            }
            // just compare & exchange
            if (el->rc_.compare_exchange_weak(
                        cur_rc, epoch_ | static_cast<rc_t>(cc), std::memory_order_release)) {
                break;
            }
            thoth::yield(k);
        }
        std::forward<F>(f)(&(el->data_));
        wt_.fetch_add(1, std::memory_order_release);
        return true;
    }

    template <typename W, typename F, typename R, typename E>
    bool pop(W* wrapper, circ::u2_t& cur, F&& f, R&& out, E* elems) {
        if (cur == cursor()) return false; // acquire
        auto* el = elems + circ::index_of(cur++);
        std::forward<F>(f)(&(el->data_));
        for (unsigned k = 0;;) {
            auto cur_rc = el->rc_.load(std::memory_order_acquire);
            if ((cur_rc & ep_mask) == 0) {
                std::forward<R>(out)(true);
                return true;
            }
            auto nxt_rc = cur_rc & ~static_cast<rc_t>(wrapper->connected_id());
            if (el->rc_.compare_exchange_weak(cur_rc, nxt_rc, std::memory_order_release)) {
                std::forward<R>(out)((nxt_rc & ep_mask) == 0);
                return true;
            }
            thoth::yield(k);
        }
    }

    // A receiver that read `since` from cursor() and then claimed `cc_id` starts
    // at the earliest element pushed since then that already carries its id: the
    // writer saw it connected, so the element is addressed to it, and an unread
    // mark would hold the writer up when it laps back to the element.
    template <typename E, std::size_t N>
    circ::u2_t adopt(circ::u2_t since, circ::cc_t cc_id, E const (&elems)[N]) const noexcept {
        circ::u2_t cur = cursor();
        for (std::size_t n = 0; (cur != since) && (n < N); ++n) {
            auto cur_rc = elems[circ::index_of(cur - 1)].rc_.load(std::memory_order_acquire);
            if (!(cur_rc & cc_id) || ((cur_rc & ~ep_mask) != epoch_)) break;
            --cur;
        }
        return cur;
    }
};

template <>
struct prod_cons_impl<wr<relat::multi, relat::multi, trans::broadcast>> {

    using rc_t   = std::uint64_t;
    using flag_t = std::uint64_t;

    enum : rc_t {
        rc_mask = 0x00000000ffffffffull,
        ep_mask = 0x00ffffffffffffffull,
        ep_incr = 0x0100000000000000ull,
        ic_mask = 0xff000000ffffffffull,
        ic_incr = 0x0000000100000000ull
    };

    template <std::size_t DataSize, std::size_t AlignSize>
    struct elem_t {
        alignas(AlignSize) byte_t data_[DataSize] {};
        std::atomic<rc_t  > rc_   { 0 }; // read-counter
        std::atomic<flag_t> f_ct_ { 0 }; // commit flag
    };

    alignas(cache_line_size) std::atomic<circ::u2_t> ct_;   // commit index
    alignas(cache_line_size) std::atomic<rc_t> epoch_ { 0 };

    circ::u2_t cursor() const noexcept {
        return ct_.load(std::memory_order_acquire);
    }

    constexpr static rc_t inc_rc(rc_t rc) noexcept {
        return (rc & ic_mask) | ((rc + ic_incr) & ~ic_mask);
    }

    constexpr static rc_t inc_mask(rc_t rc) noexcept {
        return inc_rc(rc) & ~rc_mask;
    }

    template <typename W, typename F, typename E>
    bool push(W* wrapper, F&& f, E* elems) {
        E* el;
        circ::u2_t cur_ct;
        rc_t epoch = epoch_.load(std::memory_order_acquire);
        for (unsigned k = 0;;) {
            circ::cc_t cc = wrapper->elems()->connections(std::memory_order_relaxed);
            if (cc == 0) return false; // no reader
            el = elems + circ::index_of(cur_ct = ct_.load(std::memory_order_relaxed));
            // check all consumers have finished reading this element
            auto cur_rc = el->rc_.load(std::memory_order_relaxed);
            circ::cc_t rem_cc = cur_rc & rc_mask;
            // (Every mark counts here, unlike for the single-producer route: a
            // concurrent writer may have just stamped this element for cur_ct
            // itself. A previous owner's leftover marks are dropped by the next
            // owner of the id when it connects, see release_stale().)
            if ((cc & rem_cc) && ((cur_rc & ~ep_mask) == epoch)) {
                return false; // has not finished yet
            }
            else if (!rem_cc) {
                auto cur_fl = el->f_ct_.load(std::memory_order_acquire);
                if ((cur_fl != cur_ct) && cur_fl) {
                    return false; // full
                }
            }
            // consider rem_cc to be 0 here
            if (el->rc_.compare_exchange_weak(
                        cur_rc, inc_mask(epoch | (cur_rc & ep_mask)) | static_cast<rc_t>(cc), std::memory_order_relaxed) &&
                epoch_.compare_exchange_weak(epoch, epoch, std::memory_order_acq_rel)) {
                break;
            }
            thoth::yield(k);
        }
        // only one thread/process would touch here at one time
        ct_.store(cur_ct + 1, std::memory_order_release);
        std::forward<F>(f)(&(el->data_));
        // set flag & try update wt
        el->f_ct_.store(~static_cast<flag_t>(cur_ct), std::memory_order_release);
        return true;
    }

    template <typename W, typename F, typename E>
    bool force_push(W* wrapper, F&& f, E* elems) {
        THOTH_IPC_LOG();
        E* el;
        circ::u2_t cur_ct;
        rc_t epoch = epoch_.fetch_add(ep_incr, std::memory_order_release) + ep_incr;
        for (unsigned k = 0;;) {
            circ::cc_t cc = wrapper->elems()->connections(std::memory_order_relaxed);
            if (cc == 0) return false; // no reader
            el = elems + circ::index_of(cur_ct = ct_.load(std::memory_order_relaxed));
            // check all consumers have finished reading this element
            auto cur_rc = el->rc_.load(std::memory_order_acquire);
            circ::cc_t rem_cc = cur_rc & rc_mask;
            if (cc & rem_cc) {
                log.debug("force_push: k = ", k, ", cc = ", cc, ", rem_cc = ", rem_cc);
                cc = wrapper->elems()->disconnect_receiver(rem_cc); // disconnect all invalid readers
                if (cc == 0) return false; // no reader
            }
            // just compare & exchange
            if (el->rc_.compare_exchange_weak(
                        cur_rc, inc_mask(epoch | (cur_rc & ep_mask)) | static_cast<rc_t>(cc), std::memory_order_relaxed)) {
                if (epoch == epoch_.load(std::memory_order_acquire)) {
                    break;
                }
                else if (push(wrapper, std::forward<F>(f), elems)) {
                    return true;
                }
                epoch = epoch_.fetch_add(ep_incr, std::memory_order_release) + ep_incr;
            }
            thoth::yield(k);
        }
        // only one thread/process would touch here at one time
        ct_.store(cur_ct + 1, std::memory_order_release);
        std::forward<F>(f)(&(el->data_));
        // set flag & try update wt
        el->f_ct_.store(~static_cast<flag_t>(cur_ct), std::memory_order_release);
        return true;
    }

    template <typename W, typename F, typename R, typename E, std::size_t N>
    bool pop(W* wrapper, circ::u2_t& cur, F&& f, R&& out, E(& elems)[N]) {
        auto* el = elems + circ::index_of(cur);
        auto cur_fl = el->f_ct_.load(std::memory_order_acquire);
        if (cur_fl != ~static_cast<flag_t>(cur)) {
            return false; // empty
        }
        ++cur;
        std::forward<F>(f)(&(el->data_));
        for (unsigned k = 0;;) {
            auto cur_rc = el->rc_.load(std::memory_order_acquire);
            if ((cur_rc & rc_mask) == 0) {
                std::forward<R>(out)(true);
                el->f_ct_.store(cur + N - 1, std::memory_order_release);
                return true;
            }
            auto nxt_rc = inc_rc(cur_rc) & ~static_cast<rc_t>(wrapper->connected_id());
            bool last_one = false;
            if ((last_one = (nxt_rc & rc_mask) == 0)) {
                el->f_ct_.store(cur + N - 1, std::memory_order_release);
            }
            if (el->rc_.compare_exchange_weak(cur_rc, nxt_rc, std::memory_order_release)) {
                std::forward<R>(out)(last_one);
                return true;
            }
            thoth::yield(k);
        }
    }

    // A receiver that read `since` and then claimed `cc_id` drops the marks a
    // previous owner of the id left unread: every element addressed to this
    // receiver is at or after `since`, so its id on a committed element from
    // before is a leftover, and would hold the writers up when they lap back to
    // it. It does what that owner's pop() would have: drop the mark, and release
    // the element if it was the last one. No writer can reuse such an element
    // meanwhile, since the (now connected) id still marks it.
    template <typename E, std::size_t N>
    void release_stale(circ::u2_t since, circ::cc_t cc_id, E (&elems)[N]) noexcept {
        for (auto& el : elems) {
            auto cur_fl = el.f_ct_.load(std::memory_order_acquire);
            // Committed elements hold ~position (the upper half all ones).
            if ((cur_fl >> 32) != 0xffffffffu) continue;
            auto pos = static_cast<circ::u2_t>(~cur_fl);
            if (static_cast<std::int32_t>(pos - since) >= 0) continue; // ours to read
            auto cur_rc = el.rc_.load(std::memory_order_acquire);
            while (cur_rc & cc_id) {
                auto nxt_rc = inc_rc(cur_rc) & ~static_cast<rc_t>(cc_id);
                if (el.rc_.compare_exchange_weak(cur_rc, nxt_rc, std::memory_order_release,
                                                 std::memory_order_acquire)) {
                    if ((nxt_rc & rc_mask) == 0) {
                        el.f_ct_.store(pos + N, std::memory_order_release); // as pop() releases
                    }
                    break;
                }
            }
        }
    }

    // As for the single-producer broadcast: start a receiver that read `since`
    // and then claimed `cc_id` at the earliest element claimed since then that
    // already carries its id (it may still be uncommitted; pop() waits for that).
    template <typename E, std::size_t N>
    circ::u2_t adopt(circ::u2_t since, circ::cc_t cc_id, E const (&elems)[N]) const noexcept {
        circ::u2_t cur = cursor();
        rc_t epoch = epoch_.load(std::memory_order_acquire);
        for (std::size_t n = 0; (cur != since) && (n < N); ++n) {
            auto cur_rc = elems[circ::index_of(cur - 1)].rc_.load(std::memory_order_acquire);
            if (!(cur_rc & cc_id) || ((cur_rc & ~ep_mask) != epoch)) break;
            --cur;
        }
        return cur;
    }
};

} // namespace thoth
