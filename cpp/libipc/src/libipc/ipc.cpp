#include <cstddef>
#include <cstring>
#include <algorithm>
#include <utility>          // std::pair, std::move, std::forward
#include <atomic>
#include <string>
#include <vector>
#include <array>
#include <cassert>
#include <mutex>

#include "libipc/ipc.h"
#include "libipc/def.h"
#include "libipc/shm.h"
#include "libipc/queue.h"
#include "libipc/policy.h"
#include "libipc/rw_lock.h"
#include "libipc/waiter.h"
#include "libipc/notify.h"
#include "libipc/liveness.h"

#include "libipc/imp/log.h"
#include "libipc/utility/id_pool.h"
#include "libipc/utility/scope_guard.h"
#include "libipc/utility/utility.h"

#include "libipc/mem/resource.h"
#include "libipc/mem/new.h"
#include "libipc/platform/detail.h"
#include "libipc/prod_cons.h"
#include "libipc/circ/elem_array.h"
#include "libipc/abi_generated.hpp"    // generated ipc::abi (abi/abi.json)

namespace {

using msg_id_t = std::uint32_t;
using acc_t    = std::atomic<msg_id_t>;

template <std::size_t DataSize, std::size_t AlignSize>
struct msg_t;

template <std::size_t AlignSize>
struct msg_t<0, AlignSize> {
    msg_id_t     cc_id_;
    msg_id_t     id_;
    std::int32_t remain_;
    bool         storage_;
};

template <std::size_t DataSize, std::size_t AlignSize>
struct msg_t : msg_t<0, AlignSize> {
    alignas(AlignSize) ipc::byte_t data_[DataSize] {};

    msg_t() = default;
    msg_t(msg_id_t cc_id, msg_id_t id, std::int32_t remain, void const * data, std::size_t size)
        : msg_t<0, AlignSize> {cc_id, id, remain, (data == nullptr) || (size == 0)} {
        if (this->storage_) {
            if (data != nullptr) {
                // copy storage-id
                *reinterpret_cast<ipc::storage_id_t*>(data_) =
                     *static_cast<ipc::storage_id_t const *>(data);
            }
        }
        else std::memcpy(data_, data, size);
    }
};

// -----------------------------------------------------------------------------
// ABI conformance — the C++ template-derived layout must match the generated
// ipc::abi (from abi/abi.json). C++ keeps *deriving* these values from its
// templates / def.h, so `abi/dump_abi.cpp` remains an independent ground-truth
// for the semantic gate; these compile-time asserts make C++ a *checked* peer
// of the generated Rust/Swift/Zig modules rather than collapsing that gate.
// Byte-exact target: apple_arm64 (AlignSize=8), matching dump_abi.cpp.
// -----------------------------------------------------------------------------
namespace {
using AbiRouteP = ipc::prod_cons_impl<ipc::wr<ipc::relat::single, ipc::relat::multi, ipc::trans::broadcast>>;
using AbiChanP  = ipc::prod_cons_impl<ipc::wr<ipc::relat::multi,  ipc::relat::multi, ipc::trans::broadcast>>;
using AbiRouteArr = ipc::circ::elem_array<AbiRouteP, 80, 8>;
using AbiChanArr  = ipc::circ::elem_array<AbiChanP, 80, 8>;

static_assert(ipc::data_length     == ipc::abi::data_length,     "abi drift: data_length");
static_assert(ipc::large_msg_align == ipc::abi::large_msg_align, "abi drift: large_msg_align");
static_assert(ipc::large_msg_cache == ipc::abi::large_msg_cache, "abi drift: large_msg_cache");
static_assert(AbiRouteArr::elem_max == ipc::abi::ring_size,      "abi drift: ring_size");

static_assert(sizeof(AbiRouteP::elem_t<80, 8>) == ipc::abi::route_elem_size,   "abi drift: route_elem.size");
static_assert(sizeof(AbiChanP::elem_t<80, 8>)  == ipc::abi::channel_elem_size, "abi drift: channel_elem.size");
static_assert(sizeof(AbiRouteArr) == ipc::abi::route_ring_size,   "abi drift: route_ring.size");
static_assert(sizeof(AbiChanArr)  == ipc::abi::channel_ring_size, "abi drift: channel_ring.size");
// msg_t lives here in ipc.cpp (not a header), so dump_abi.cpp cannot reach it —
// this sizeof assert extends C++ conformance to the message framing. (Field
// offsets are left to the matrix: msg_t is a non-standard-layout type, so
// offsetof on it is ill-formed.)
static_assert(sizeof(msg_t<64, 8>) == ipc::abi::msg_t_size, "abi drift: msg_t.size");

static_assert(AbiRouteP::ep_mask == ipc::abi::route_ep_mask, "abi drift: route_ep_mask");
static_assert(AbiRouteP::ep_incr == ipc::abi::route_ep_incr, "abi drift: route_ep_incr");
static_assert(AbiChanP::rc_mask  == ipc::abi::chan_rc_mask,  "abi drift: chan_rc_mask");
static_assert(AbiChanP::ep_mask  == ipc::abi::chan_ep_mask,  "abi drift: chan_ep_mask");
static_assert(AbiChanP::ep_incr  == ipc::abi::chan_ep_incr,  "abi drift: chan_ep_incr");
static_assert(AbiChanP::ic_mask  == ipc::abi::chan_ic_mask,  "abi drift: chan_ic_mask");
static_assert(AbiChanP::ic_incr  == ipc::abi::chan_ic_incr,  "abi drift: chan_ic_incr");

// Liveness slot-owner table (LV_CONN__ segment, libipc/liveness.h). slot_owner
// is standard-layout (two atomic fields, no bases), so offsetof is well-formed.
static_assert(sizeof(ipc::detail::slot_owner) == ipc::abi::liveness_slot_size,
              "abi drift: liveness_slot.size");
static_assert(offsetof(ipc::detail::slot_owner, pid)       == ipc::abi::liveness_slot_pid_off,
              "abi drift: liveness_slot.pid_off");
static_assert(offsetof(ipc::detail::slot_owner, start_tok) == ipc::abi::liveness_slot_start_tok_off,
              "abi drift: liveness_slot.start_tok_off");
} // namespace

template <typename T>
ipc::buff_t make_cache(T &data, std::size_t size) {
    auto *ptr = ipc::mem::$new<void>(size);
    std::memcpy(ptr, &data, (ipc::detail::min)(sizeof(data), size));
    return {
        ptr, size, 
        [](void *p, std::size_t) noexcept {
            ipc::mem::$delete(p);
        }
    };
}

acc_t *cc_acc(std::string const &pref) {
    LIBIPC_LOG();
    static auto *phs = new ipc::unordered_map<std::string, ipc::shm::handle>; // no delete
    static std::mutex lock;
    std::lock_guard<std::mutex> guard {lock};
    auto it = phs->find(pref);
    if (it == phs->end()) {
        std::string shm_name {ipc::make_prefix(pref, "CA_CONN__")};
        ipc::shm::handle h;
        if (!h.acquire(shm_name.c_str(), sizeof(acc_t))) {
            log.error("[cc_acc] acquire failed: ", shm_name);
            return nullptr;
        }
        it = phs->emplace(pref, std::move(h)).first;
    }
    return static_cast<acc_t *>(it->second.get());
}

struct cache_t {
    std::size_t fill_;
    ipc::buff_t buff_;

    cache_t(std::size_t f, ipc::buff_t && b)
        : fill_(f), buff_(std::move(b))
    {}

    void append(void const * data, std::size_t size) {
        if (fill_ >= buff_.size() || data == nullptr || size == 0) return;
        auto new_fill = (ipc::detail::min)(fill_ + size, buff_.size());
        std::memcpy(static_cast<ipc::byte_t*>(buff_.data()) + fill_, data, new_fill - fill_);
        fill_ = new_fill;
    }
};

struct conn_info_head {

    std::string prefix_;
    std::string name_;
    msg_id_t    cc_id_; // connection-info id
    ipc::detail::waiter cc_waiter_, wt_waiter_, rd_waiter_;
    ipc::shm::handle acc_h_;
    ipc::shm::handle lv_h_; // LV_CONN__ per-slot owner table (dead-connection reaper)

    // Per-slot owner table (dead-connection reaper, RFC:
    // context/dead-connection-reaper-rfc.md). Lives in its own segment so the
    // byte-exact ring/waiter segments are untouched.
    ipc::detail::conn_liveness *liveness() noexcept {
        return static_cast<ipc::detail::conn_liveness *>(lv_h_.get());
    }
    void liveness_set_owner(ipc::circ::cc_t bit) noexcept {
        ipc::detail::liveness_set_owner(liveness(), bit);
    }
    void liveness_clear_owner(ipc::circ::cc_t bit) noexcept {
        ipc::detail::liveness_clear_owner(liveness(), bit);
    }
    // Reclaim a reaped slot's readiness FIFO (no-op unless the FIFO notify backend is on).
    void notify_clear_slot(ipc::circ::cc_t bit) noexcept {
#if defined(LIBIPC_NOTIFY_FD)
        ipc::detail::notify_clear_slot(prefix_, name_, bit);
#else
        (void)bit;
#endif
    }

#if defined(LIBIPC_NOTIFY_FD)
    // Opt-in Layer 1 (RFC context/stdexec-async-recv-rfc.md). notify_sink_ owns
    // this receiver's per-slot FIFO; notify_source_ pokes connected readers on
    // enqueue. Both are inert (no fds, no syscalls) until actually opened.
    ipc::detail::notify_sink   notify_sink_;
    ipc::detail::notify_source notify_source_;

    void notify_open_sink(ipc::circ::cc_t slot_bit) {
        // slot_bit selects the reader slot for the FIFO backend; the libnotify
        // backend ignores it (one multicast name per channel).
        notify_sink_.open(prefix_, name_, slot_bit);
    }
    void notify_close_sink() noexcept {
        notify_sink_.close();
    }
    ipc::wait_handle_t notify_wait_handle() const noexcept {
        return notify_sink_.valid() ? notify_sink_.native_handle()
                                    : ipc::invalid_wait_handle;
    }
    // Signal every connected reader (bitmap from the queue), skipping our own
    // receiver slot so a bidirectional handle never wakes itself.
    template <typename Q>
    void notify_signal(Q *que) noexcept {
        auto *elems = que->elems();
        if (elems == nullptr) return;
        notify_source_.signal(prefix_, name_,
                              elems->connections(), que->connected_id());
    }
#endif

    conn_info_head(char const * prefix, char const * name)
        : prefix_{ipc::make_string(prefix)}
        , name_  {ipc::make_string(name)}
        , cc_id_ {} {}

    void init() {
        if (!cc_waiter_.valid()) cc_waiter_.open(ipc::make_prefix(prefix_, "CC_CONN__", name_).c_str());
        if (!wt_waiter_.valid()) wt_waiter_.open(ipc::make_prefix(prefix_, "WT_CONN__", name_).c_str());
        if (!rd_waiter_.valid()) rd_waiter_.open(ipc::make_prefix(prefix_, "RD_CONN__", name_).c_str());
        if (!acc_h_.valid()) acc_h_.acquire(ipc::make_prefix(prefix_, "AC_CONN__", name_).c_str(), sizeof(acc_t));
        if (!lv_h_.valid()) lv_h_.acquire(ipc::make_prefix(prefix_, "LV_CONN__", name_).c_str(), sizeof(ipc::detail::conn_liveness));
        if (cc_id_ != 0) {
            return;
        }
        acc_t *pacc = cc_acc(prefix_);
        if (pacc == nullptr) {
            // Failed to obtain the global accumulator.
            return;
        }
        cc_id_ = pacc->fetch_add(1, std::memory_order_relaxed) + 1;
        if (cc_id_ == 0) {
            // The identity cannot be 0.
            cc_id_ = pacc->fetch_add(1, std::memory_order_relaxed) + 1;
        }
    }

    void clear() noexcept {
        cc_waiter_.clear();
        wt_waiter_.clear();
        rd_waiter_.clear();
        acc_h_.clear();
        lv_h_.clear();
    }

    static void clear_storage(char const * prefix, char const * name) noexcept {
        auto p = ipc::make_string(prefix);
        auto n = ipc::make_string(name);
        ipc::detail::waiter::clear_storage(ipc::make_prefix(p, "CC_CONN__", n).c_str());
        ipc::detail::waiter::clear_storage(ipc::make_prefix(p, "WT_CONN__", n).c_str());
        ipc::detail::waiter::clear_storage(ipc::make_prefix(p, "RD_CONN__", n).c_str());
        ipc::shm::handle::clear_storage(ipc::make_prefix(p, "AC_CONN__", n).c_str());
        ipc::shm::handle::clear_storage(ipc::make_prefix(p, "LV_CONN__", n).c_str());
#if defined(LIBIPC_NOTIFY_FD)
        ipc::detail::notify_clear_storage(p, n);
#endif
    }

    void quit_waiting() {
        cc_waiter_.quit_waiting();
        wt_waiter_.quit_waiting();
        rd_waiter_.quit_waiting();
    }

    auto acc() {
        return static_cast<acc_t*>(acc_h_.get());
    }

    auto& recv_cache() {
        thread_local ipc::unordered_map<msg_id_t, cache_t> tls;
        return tls;
    }
};

IPC_CONSTEXPR_ std::size_t align_chunk_size(std::size_t size) noexcept {
    return (((size - 1) / ipc::large_msg_align) + 1) * ipc::large_msg_align;
}

IPC_CONSTEXPR_ std::size_t calc_chunk_size(std::size_t size) noexcept {
    return ipc::make_align(alignof(std::max_align_t), align_chunk_size(
           ipc::make_align(alignof(std::max_align_t), sizeof(std::atomic<ipc::circ::cc_t>)) + size));
}

struct chunk_t {
    std::atomic<ipc::circ::cc_t> &conns() noexcept {
        return *reinterpret_cast<std::atomic<ipc::circ::cc_t> *>(this);
    }

    void *data() noexcept {
        return reinterpret_cast<ipc::byte_t *>(this)
             + ipc::make_align(alignof(std::max_align_t), sizeof(std::atomic<ipc::circ::cc_t>));
    }
};

struct chunk_info_t {
    ipc::id_pool<> pool_;
    ipc::spin_lock lock_;

    IPC_CONSTEXPR_ static std::size_t chunks_mem_size(std::size_t chunk_size) noexcept {
        return ipc::id_pool<>::max_count * chunk_size;
    }

    ipc::byte_t *chunks_mem() noexcept {
        return reinterpret_cast<ipc::byte_t *>(this + 1);
    }

    chunk_t *at(std::size_t chunk_size, ipc::storage_id_t id) noexcept {
        if (id < 0) return nullptr;
        return reinterpret_cast<chunk_t *>(chunks_mem() + (chunk_size * id));
    }
};

// -----------------------------------------------------------------------------
// ABI conformance — the large-message chunk layout must match the generated
// ipc::abi (from abi/abi.json). chunk_info_t / chunk_t live in this TU (not a
// header), so dump_abi.cpp cannot reach them; C++ keeps deriving these values
// from its own definitions (chunk_info_t, make_align, def.h). The per-chunk
// header size is the same make_align expression chunk_t::data() uses.
//
// Apple-only: both values depend on alignof(std::max_align_t) (8 on Apple, 16 on
// Linux/Win x86-64) — chunk_header directly, chunk_info via the lock's alignment.
// The generated values are the apple_arm64 target, so guard the check to Apple
// (the transport asserts above stay portable only because they force AlignSize=8
// through the elem_array template parameter, which is not possible here).
// -----------------------------------------------------------------------------
#if defined(__APPLE__)
namespace {
static_assert(sizeof(chunk_info_t) == ipc::abi::chunk_info_size, "abi drift: chunk_info.size");
static_assert(ipc::make_align(alignof(std::max_align_t), sizeof(std::atomic<ipc::circ::cc_t>))
                  == ipc::abi::chunk_header_size, "abi drift: chunk_header_size");
} // namespace
#endif

auto& chunk_storages() {
    class chunk_handle_t {
        ipc::unordered_map<std::string, ipc::shm::handle> handles_;
        std::mutex lock_;

        static bool make_handle(ipc::shm::handle &h, std::string const &shm_name, std::size_t chunk_size) {
            LIBIPC_LOG();
            if (!h.valid() &&
                !h.acquire( shm_name.c_str(), 
                            sizeof(chunk_info_t) + chunk_info_t::chunks_mem_size(chunk_size) )) {
                log.error("[chunk_storages] chunk_shm.id_info_.acquire failed: chunk_size = ", chunk_size);
                return false;
            }
            return true;
        }

    public:
        chunk_info_t *get_info(conn_info_head *inf, std::size_t chunk_size) {
            LIBIPC_LOG();
            std::string pref {(inf == nullptr) ? std::string{} : inf->prefix_};
            std::string shm_name {ipc::make_prefix(pref, "CHUNK_INFO__", chunk_size)};
            ipc::shm::handle *h;
            {
                std::lock_guard<std::mutex> guard {lock_};
                h = &(handles_[pref]);
                if (!make_handle(*h, shm_name, chunk_size)) {
                    return nullptr;
                }
            }
            auto *info = static_cast<chunk_info_t*>(h->get());
            if (info == nullptr) {
                log.error("[chunk_storages] chunk_shm.id_info_.get failed: chunk_size = ", chunk_size);
                return nullptr;
            }
            return info;
        }
    };
    using deleter_t = void (*)(chunk_handle_t*);
    using chunk_handle_ptr_t = std::unique_ptr<chunk_handle_t, deleter_t>;
    static auto *chunk_hs = new ipc::map<std::size_t, chunk_handle_ptr_t>; // no delete
    return *chunk_hs;
}

chunk_info_t *chunk_storage_info(conn_info_head *inf, std::size_t chunk_size) {
    auto &storages = chunk_storages();
    std::decay_t<decltype(storages)>::iterator it;
    {
        static ipc::rw_lock lock;
        LIBIPC_UNUSED std::shared_lock<ipc::rw_lock> guard {lock};
        if ((it = storages.find(chunk_size)) == storages.end()) {
            using chunk_handle_ptr_t = std::decay_t<decltype(storages)>::value_type::second_type;
            using chunk_handle_t     = chunk_handle_ptr_t::element_type;
            guard.unlock();
            LIBIPC_UNUSED std::lock_guard<ipc::rw_lock> guard {lock};
            it = storages.emplace(chunk_size, chunk_handle_ptr_t{
                ipc::mem::$new<chunk_handle_t>(), [](chunk_handle_t *p) {
                    ipc::mem::$delete(p);
                }}).first;
        }
    }
    return it->second->get_info(inf, chunk_size);
}

std::pair<ipc::storage_id_t, void*> acquire_storage(conn_info_head *inf, std::size_t size, ipc::circ::cc_t conns) {
    std::size_t chunk_size = calc_chunk_size(size);
    auto info = chunk_storage_info(inf, chunk_size);
    if (info == nullptr) return {};

    info->lock_.lock();
    info->pool_.prepare();
    // got an unique id
    auto id = info->pool_.acquire();
    info->lock_.unlock();

    auto chunk = info->at(chunk_size, id);
    if (chunk == nullptr) return {};
    chunk->conns().store(conns, std::memory_order_relaxed);
    return { id, chunk->data() };
}

void *find_storage(ipc::storage_id_t id, conn_info_head *inf, std::size_t size) {
    LIBIPC_LOG();
    if (id < 0) {
        log.error("[find_storage] id is invalid: id = ", (long)id, ", size = ", size);
        return nullptr;
    }
    std::size_t chunk_size = calc_chunk_size(size);
    auto info = chunk_storage_info(inf, chunk_size);
    if (info == nullptr) return nullptr;
    return info->at(chunk_size, id)->data();
}

void release_storage(ipc::storage_id_t id, conn_info_head *inf, std::size_t size) {
    LIBIPC_LOG();
    if (id < 0) {
        log.error("[release_storage] id is invalid: id = ", (long)id, ", size = ", size);
        return;
    }
    std::size_t chunk_size = calc_chunk_size(size);
    auto info = chunk_storage_info(inf, chunk_size);
    if (info == nullptr) return;
    info->lock_.lock();
    info->pool_.release(id);
    info->lock_.unlock();
}

template <ipc::relat Rp, ipc::relat Rc>
bool sub_rc(ipc::wr<Rp, Rc, ipc::trans::unicast>, 
            std::atomic<ipc::circ::cc_t> &/*conns*/, ipc::circ::cc_t /*curr_conns*/, ipc::circ::cc_t /*conn_id*/) noexcept {
    return true;
}

template <ipc::relat Rp, ipc::relat Rc>
bool sub_rc(ipc::wr<Rp, Rc, ipc::trans::broadcast>, 
            std::atomic<ipc::circ::cc_t> &conns, ipc::circ::cc_t curr_conns, ipc::circ::cc_t conn_id) noexcept {
    auto last_conns = curr_conns & ~conn_id;
    for (unsigned k = 0;;) {
        auto chunk_conns  = conns.load(std::memory_order_acquire);
        if (conns.compare_exchange_weak(chunk_conns, chunk_conns & last_conns, std::memory_order_release)) {
            return (chunk_conns & last_conns) == 0;
        }
        ipc::yield(k);
    }
}

template <typename Flag>
void recycle_storage(ipc::storage_id_t id, conn_info_head *inf, std::size_t size, ipc::circ::cc_t curr_conns, ipc::circ::cc_t conn_id) {
    LIBIPC_LOG();
    if (id < 0) {
        log.error("[recycle_storage] id is invalid: id = ", (long)id, ", size = ", size);
        return;
    }
    std::size_t chunk_size = calc_chunk_size(size);
    auto info = chunk_storage_info(inf, chunk_size);
    if (info == nullptr) return;

    auto chunk = info->at(chunk_size, id);
    if (chunk == nullptr) return;

    if (!sub_rc(Flag{}, chunk->conns(), curr_conns, conn_id)) {
        return;
    }
    info->lock_.lock();
    info->pool_.release(id);
    info->lock_.unlock();
}

template <typename MsgT>
bool clear_message(conn_info_head *inf, void* p) {
    LIBIPC_LOG();
    auto msg = static_cast<MsgT*>(p);
    if (msg->storage_) {
        std::int32_t r_size = static_cast<std::int32_t>(ipc::data_length) + msg->remain_;
        if (r_size <= 0) {
            log.error("[clear_message] invalid msg size: ", (int)r_size);
            return true;
        }
        release_storage(*reinterpret_cast<ipc::storage_id_t*>(&msg->data_),
                        inf, static_cast<std::size_t>(r_size));
    }
    return true;
}

template <typename W, typename F>
bool wait_for(W& waiter, F&& pred, std::uint64_t tm) {
    if (tm == 0) return !pred();
    for (unsigned k = 0; pred();) {
        bool ret = true;
        ipc::sleep(k, [&k, &ret, &waiter, &pred, tm] {
            ret = waiter.wait_if(std::forward<F>(pred), tm);
            k   = 0;
        });
        if (!ret) return false; // timeout or fail
        if (k == 0) break; // k has been reset
    }
    return true;
}

template <typename Policy,
          std::size_t DataSize  = ipc::data_length,
          std::size_t AlignSize = (ipc::detail::min)(DataSize, alignof(std::max_align_t))>
struct queue_generator {

    using queue_t = ipc::queue<msg_t<DataSize, AlignSize>, Policy>;

    struct conn_info_t : conn_info_head {
        queue_t que_;

        conn_info_t(char const * pref, char const * name)
            : conn_info_head{pref, name} { init(); }

        void init() {
            conn_info_head::init();
            if (!que_.valid()) {
                que_.open(ipc::make_prefix(prefix_,
                          "QU_CONN__",
                          this->name_,
                          "__", DataSize,
                          "__", AlignSize).c_str());
            }
            // Dead-connection reaping is only meaningful for broadcast (cc_ is a
            // per-receiver bitmask); non-broadcast uses cc_ as a plain count.
            if constexpr (ipc::relat_trait<typename queue_t::policy_t>::is_broadcast) {
                que_.set_liveness(this->liveness());
            }
        }

        void clear() noexcept {
            que_.clear();
            conn_info_head::clear();
        }

        static void clear_storage(char const * prefix, char const * name) noexcept {
            queue_t::clear_storage(ipc::make_prefix(prefix, 
                                   "QU_CONN__", 
                                   name, 
                                   "__", DataSize, 
                                   "__", AlignSize).c_str());
            conn_info_head::clear_storage(prefix, name);
        }

        void disconnect_receiver() {
            ipc::circ::cc_t self = que_.connected_id();
            bool dis = que_.disconnect();
            this->quit_waiting();
            if (dis) {
                if constexpr (ipc::relat_trait<typename queue_t::policy_t>::is_broadcast) {
                    this->liveness_clear_owner(self);
                }
                this->recv_cache().clear();
#if defined(LIBIPC_NOTIFY_FD)
                this->notify_close_sink();
#endif
            }
        }

        // Clear the cc_ bits of any receivers whose owner process has died
        // (dead-connection reaper). Callable by any participant; run on connect so
        // a new joiner reclaims phantom slots before claiming one. Broadcast only.
        ipc::circ::cc_t reap() noexcept {
            if constexpr (ipc::relat_trait<typename queue_t::policy_t>::is_broadcast) {
                auto *elems = que_.elems();
                if (elems == nullptr) return 0;
                return ipc::detail::reap_dead_receivers(
                    this->liveness(), elems->connections(),
                    [elems](ipc::circ::cc_t bit) { elems->disconnect_receiver(bit); },
                    [this](ipc::circ::cc_t bit) { this->notify_clear_slot(bit); });
            } else {
                return 0;
            }
        }
    };
};

template <typename Policy>
struct detail_impl {

using policy_t    = Policy;
using flag_t      = typename policy_t::flag_t;
using queue_t     = typename queue_generator<policy_t>::queue_t;
using conn_info_t = typename queue_generator<policy_t>::conn_info_t;

constexpr static conn_info_t* info_of(ipc::handle_t h) noexcept {
    return static_cast<conn_info_t*>(h);
}

constexpr static queue_t* queue_of(ipc::handle_t h) noexcept {
    return (info_of(h) == nullptr) ? nullptr : &(info_of(h)->que_);
}

/* API implementations */

static bool connect(ipc::handle_t * ph, ipc::prefix pref, char const * name, bool start_to_recv) {
    assert(ph != nullptr);
    if (*ph == nullptr) {
        *ph = ipc::mem::$new<conn_info_t>(pref.str, name);
    }
    return reconnect(ph, start_to_recv);
}

static bool connect(ipc::handle_t * ph, char const * name, bool start_to_recv) {
    return connect(ph, {nullptr}, name, start_to_recv);
}

static void disconnect(ipc::handle_t h) {
    auto que = queue_of(h);
    if (que == nullptr) {
        return;
    }
    que->shut_sending();
    assert(info_of(h) != nullptr);
    info_of(h)->disconnect_receiver();
}

static bool reconnect(ipc::handle_t * ph, bool start_to_recv) {
    assert(ph != nullptr);
    assert(*ph != nullptr);
    auto que = queue_of(*ph);
    if (que == nullptr) {
        return false;
    }
    info_of(*ph)->init();
    if (start_to_recv) {
        que->shut_sending();
        info_of(*ph)->reap(); // reclaim slots held by dead peers before claiming one (broadcast-only)
        if (que->connect()) { // wouldn't connect twice
            if constexpr (ipc::relat_trait<typename queue_t::policy_t>::is_broadcast) {
                info_of(*ph)->liveness_set_owner(que->connected_id());
            }
            info_of(*ph)->cc_waiter_.broadcast();
#if defined(LIBIPC_NOTIFY_FD)
            // Now that we own a reader slot, create its readiness FIFO.
            info_of(*ph)->notify_open_sink(que->connected_id());
#endif
            return true;
        }
        return false;
    }
    // start_to_recv == false
    if (que->connected()) {
        info_of(*ph)->disconnect_receiver();
    }
    return que->ready_sending();
}

static void destroy(ipc::handle_t h) noexcept {
    ipc::mem::$delete(info_of(h));
}

static std::size_t recv_count(ipc::handle_t h) noexcept {
    auto que = queue_of(h);
    if (que == nullptr) {
        return ipc::invalid_value;
    }
    return que->conn_count();
}

static bool wait_for_recv(ipc::handle_t h, std::size_t r_count, std::uint64_t tm) {
    auto que = queue_of(h);
    if (que == nullptr) {
        return false;
    }
    return wait_for(info_of(h)->cc_waiter_, [que, r_count] {
        return que->conn_count() < r_count;
    }, tm);
}

template <typename F>
static bool send(F&& gen_push, ipc::handle_t h, void const * data, std::size_t size) {
    LIBIPC_LOG();
    if (data == nullptr || size == 0) {
        log.error("fail: send(", data, ", ", size, ")");
        return false;
    }
    auto que = queue_of(h);
    if (que == nullptr) {
        log.error("fail: send, queue_of(h) == nullptr");
        return false;
    }
    if (que->elems() == nullptr) {
        log.error("fail: send, queue_of(h)->elems() == nullptr");
        return false;
    }
    if (!que->ready_sending()) {
        log.error("fail: send, que->ready_sending() == false");
        return false;
    }
    ipc::circ::cc_t conns = que->elems()->connections(std::memory_order_relaxed);
    if (conns == 0) {
        log.error("fail: send, there is no receiver on this connection.");
        return false;
    }
    // calc a new message id
    conn_info_t *inf = info_of(h);
    auto acc = inf->acc();
    if (acc == nullptr) {
        log.error("fail: send, info_of(h)->acc() == nullptr");
        return false;
    }
    auto msg_id   = acc->fetch_add(1, std::memory_order_relaxed);
    auto try_push = std::forward<F>(gen_push)(inf, que, msg_id);
    if (size > ipc::large_msg_limit) {
        auto   dat = acquire_storage(inf, size, conns);
        void * buf = dat.second;
        if (buf != nullptr) {
            std::memcpy(buf, data, size);
            return try_push(static_cast<std::int32_t>(size) - 
                            static_cast<std::int32_t>(ipc::data_length), &(dat.first), 0);
        }
        // try using message fragment
        //log.debug("fail: shm::handle for big message. msg_id: ", msg_id, ", size: ", size);
    }
    // push message fragment
    std::int32_t offset = 0;
    for (std::int32_t i = 0; i < static_cast<std::int32_t>(size / ipc::data_length); ++i, offset += ipc::data_length) {
        if (!try_push(static_cast<std::int32_t>(size) - offset - static_cast<std::int32_t>(ipc::data_length),
                      static_cast<ipc::byte_t const *>(data) + offset, ipc::data_length)) {
            return false;
        }
    }
    // if remain > 0, this is the last message fragment
    std::int32_t remain = static_cast<std::int32_t>(size) - offset;
    if (remain > 0) {
        if (!try_push(remain - static_cast<std::int32_t>(ipc::data_length),
                      static_cast<ipc::byte_t const *>(data) + offset, 
                      static_cast<std::size_t>(remain))) {
            return false;
        }
    }
    return true;
}

static bool send(ipc::handle_t h, void const * data, std::size_t size, std::uint64_t tm) {
    LIBIPC_LOG();
    return send([tm, &log](auto *info, auto *que, auto msg_id) {
        return [tm, &log, info, que, msg_id](std::int32_t remain, void const * data, std::size_t size) {
            if (!wait_for(info->wt_waiter_, [&] {
                    return !que->push(
                        [](void*) { return true; },
                        info->cc_id_, msg_id, remain, data, size);
                }, tm)) {
                log.debug("force_push: msg_id = ", msg_id, ", remain = ", remain, ", size = ", size);
                if (!que->force_push(
                        [info](void* p) { return clear_message<typename queue_t::value_t>(info, p); },
                        info->cc_id_, msg_id, remain, data, size)) {
                    return false;
                }
            }
            info->rd_waiter_.broadcast();
#if defined(LIBIPC_NOTIFY_FD)
            info->notify_signal(que);
#endif
            return true;
        };
    }, h, data, size);
}

static bool try_send(ipc::handle_t h, void const * data, std::size_t size, std::uint64_t tm) {
    return send([tm](auto *info, auto *que, auto msg_id) {
        return [tm, info, que, msg_id](std::int32_t remain, void const * data, std::size_t size) {
            if (!wait_for(info->wt_waiter_, [&] {
                    return !que->push(
                        [](void*) { return true; },
                        info->cc_id_, msg_id, remain, data, size);
                }, tm)) {
                return false;
            }
            info->rd_waiter_.broadcast();
#if defined(LIBIPC_NOTIFY_FD)
            info->notify_signal(que);
#endif
            return true;
        };
    }, h, data, size);
}

static ipc::buff_t recv(ipc::handle_t h, std::uint64_t tm) {
    LIBIPC_LOG();
    auto que = queue_of(h);
    if (que == nullptr) {
        log.error("fail: recv, queue_of(h) == nullptr");
        return {};
    }
    if (!que->connected()) {
        // hasn't connected yet, just return.
        return {};
    }
    conn_info_t *inf = info_of(h);
    auto& rc = inf->recv_cache();
    for (;;) {
        // pop a new message
        typename queue_t::value_t msg {};
        if (!wait_for(inf->rd_waiter_, [que, &msg, &h] {
                if (!que->connected()) {
                    reconnect(&h, true);
                }
                return !que->pop(msg);
            }, tm)) {
            // pop failed, just return.
            return {};
        }
        inf->wt_waiter_.broadcast();
        if ((inf->acc() != nullptr) && (msg.cc_id_ == inf->cc_id_)) {
            continue; // ignore message to self
        }
        // msg.remain_ may minus & abs(msg.remain_) < data_length
        std::int32_t r_size = static_cast<std::int32_t>(ipc::data_length) + msg.remain_;
        if (r_size <= 0) {
            log.error("fail: recv, r_size = ", (int)r_size);
            return {};
        }
        std::size_t msg_size = static_cast<std::size_t>(r_size);
        // large message
        if (msg.storage_) {
            ipc::storage_id_t buf_id = *reinterpret_cast<ipc::storage_id_t*>(&msg.data_);
            void* buf = find_storage(buf_id, inf, msg_size);
            if (buf != nullptr) {
                struct recycle_t {
                    ipc::storage_id_t storage_id;
                    conn_info_t *     inf;
                    ipc::circ::cc_t   curr_conns;
                    ipc::circ::cc_t   conn_id;
                } *r_info = ipc::mem::$new<recycle_t>(recycle_t{
                    buf_id, 
                    inf, 
                    que->elems()->connections(std::memory_order_relaxed), 
                    que->connected_id()
                });
                if (r_info == nullptr) {
                    log.error("fail: ipc::mem::$new<recycle_t>.");
                    return ipc::buff_t{buf, msg_size}; // no recycle
                } else {
                    return ipc::buff_t{buf, msg_size, [](void* p_info, std::size_t size) {
                        auto r_info = static_cast<recycle_t *>(p_info);
                        LIBIPC_UNUSED auto finally = ipc::guard([r_info] {
                            ipc::mem::$delete(r_info);
                        });
                        recycle_storage<flag_t>(r_info->storage_id, 
                                                r_info->inf, 
                                                size, 
                                                r_info->curr_conns, 
                                                r_info->conn_id);
                    }, r_info};
                }
            } else {
                log.error("fail: shm::handle for large message. msg_id: ", msg.id_, ", buf_id: ", buf_id, ", size: ", msg_size);
                continue;
            }
        }
        // find cache with msg.id_
        auto cac_it = rc.find(msg.id_);
        if (cac_it == rc.end()) {
            if (msg_size <= ipc::data_length) {
                return make_cache(msg.data_, msg_size);
            }
            // gc
            if (rc.size() > 1024) {
                std::vector<msg_id_t> need_del;
                for (auto const & pair : rc) {
                    auto cmp = std::minmax(msg.id_, pair.first);
                    if (cmp.second - cmp.first > 8192) {
                        need_del.push_back(pair.first);
                    }
                }
                for (auto id : need_del) rc.erase(id);
            }
            // cache the first message fragment
            rc.emplace(msg.id_, cache_t { ipc::data_length, make_cache(msg.data_, msg_size) });
        }
        // has cached before this message
        else {
            auto& cac = cac_it->second;
            // this is the last message fragment
            if (msg.remain_ <= 0) {
                cac.append(&(msg.data_), msg_size);
                // finish this message, erase it from cache
                auto buff = std::move(cac.buff_);
                rc.erase(cac_it);
                return buff;
            }
            // there are remain datas after this message
            cac.append(&(msg.data_), ipc::data_length);
        }
    }
}

static ipc::buff_t try_recv(ipc::handle_t h) {
    return recv(h, 0);
}

static ipc::wait_handle_t native_wait_handle(ipc::handle_t h) noexcept {
    auto *inf = info_of(h);
#if defined(LIBIPC_NOTIFY_FD)
    if (inf != nullptr) return inf->notify_wait_handle();
#endif
    (void)inf;
    return ipc::invalid_wait_handle;
}

}; // detail_impl<Policy>

template <typename Flag>
using policy_t = ipc::policy::choose<ipc::circ::elem_array, Flag>;

} // internal-linkage

namespace ipc {

template <typename Flag>
ipc::handle_t chan_impl<Flag>::init_first() {
    ipc::detail::waiter::init();
    return nullptr;
}

template <typename Flag>
bool chan_impl<Flag>::connect(ipc::handle_t * ph, char const * name, unsigned mode) {
    return detail_impl<policy_t<Flag>>::connect(ph, name, mode & receiver);
}

template <typename Flag>
bool chan_impl<Flag>::connect(ipc::handle_t * ph, prefix pref, char const * name, unsigned mode) {
    return detail_impl<policy_t<Flag>>::connect(ph, pref, name, mode & receiver);
}

template <typename Flag>
bool chan_impl<Flag>::reconnect(ipc::handle_t * ph, unsigned mode) {
    return detail_impl<policy_t<Flag>>::reconnect(ph, mode & receiver);
}

template <typename Flag>
void chan_impl<Flag>::disconnect(ipc::handle_t h) {
    detail_impl<policy_t<Flag>>::disconnect(h);
}

template <typename Flag>
void chan_impl<Flag>::destroy(ipc::handle_t h) {
    disconnect(h);
    detail_impl<policy_t<Flag>>::destroy(h);
}

template <typename Flag>
void chan_impl<Flag>::release(ipc::handle_t h) noexcept {
    detail_impl<policy_t<Flag>>::destroy(h);
}

template <typename Flag>
char const * chan_impl<Flag>::name(ipc::handle_t h) {
    auto *info = detail_impl<policy_t<Flag>>::info_of(h);
    return (info == nullptr) ? nullptr : info->name_.c_str();
}

template <typename Flag>
void chan_impl<Flag>::clear(ipc::handle_t h) noexcept {
    disconnect(h);
    using conn_info_t = typename detail_impl<policy_t<Flag>>::conn_info_t;
    auto conn_info_p = static_cast<conn_info_t *>(h);
    if (conn_info_p == nullptr) return;
    conn_info_p->clear();
    destroy(h);
}

template <typename Flag>
void chan_impl<Flag>::clear_storage(char const * name) noexcept {
    chan_impl<Flag>::clear_storage({nullptr}, name);
}

template <typename Flag>
void chan_impl<Flag>::clear_storage(prefix pref, char const * name) noexcept {
    using conn_info_t = typename detail_impl<policy_t<Flag>>::conn_info_t;
    conn_info_t::clear_storage(pref.str, name);
}

template <typename Flag>
std::size_t chan_impl<Flag>::recv_count(ipc::handle_t h) {
    return detail_impl<policy_t<Flag>>::recv_count(h);
}

template <typename Flag>
bool chan_impl<Flag>::wait_for_recv(ipc::handle_t h, std::size_t r_count, std::uint64_t tm) {
    return detail_impl<policy_t<Flag>>::wait_for_recv(h, r_count, tm);
}

template <typename Flag>
bool chan_impl<Flag>::send(ipc::handle_t h, void const * data, std::size_t size, std::uint64_t tm) {
    return detail_impl<policy_t<Flag>>::send(h, data, size, tm);
}

template <typename Flag>
buff_t chan_impl<Flag>::recv(ipc::handle_t h, std::uint64_t tm) {
    return detail_impl<policy_t<Flag>>::recv(h, tm);
}

template <typename Flag>
bool chan_impl<Flag>::try_send(ipc::handle_t h, void const * data, std::size_t size, std::uint64_t tm) {
    return detail_impl<policy_t<Flag>>::try_send(h, data, size, tm);
}

template <typename Flag>
buff_t chan_impl<Flag>::try_recv(ipc::handle_t h) {
    return detail_impl<policy_t<Flag>>::try_recv(h);
}

template <typename Flag>
wait_handle_t chan_impl<Flag>::native_wait_handle(ipc::handle_t h) noexcept {
    return detail_impl<policy_t<Flag>>::native_wait_handle(h);
}

template struct chan_impl<ipc::wr<relat::single, relat::single, trans::unicast  >>;
// template struct chan_impl<ipc::wr<relat::single, relat::multi , trans::unicast  >>; // TBD
// template struct chan_impl<ipc::wr<relat::multi , relat::multi , trans::unicast  >>; // TBD
template struct chan_impl<ipc::wr<relat::single, relat::multi , trans::broadcast>>;
template struct chan_impl<ipc::wr<relat::multi , relat::multi , trans::broadcast>>;

} // namespace ipc
