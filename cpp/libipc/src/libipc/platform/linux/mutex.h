#pragma once

#include <cstdint>
#include <system_error>
#include <mutex>
#include <atomic>
#include <vector>

#include "libipc/platform/detail.h"
#include "libipc/imp/log.h"
#include "libipc/mem/resource.h"
#include "libipc/shm.h"

#include "get_wait_time.h"
#include "sync_obj_impl.h"

#include "a0/err_macro.h"
#include "a0/mtx.h"

namespace ipc {
namespace detail {
namespace sync {

class robust_mutex : public sync::obj_impl<a0_mtx_t> {
public:
    bool lock(std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        for (;;) {
            auto ts = linux_::detail::make_timespec(tm);
            int eno = A0_SYSERR(
                (tm == invalid_value) ? a0_mtx_lock(native()) 
                                      : a0_mtx_timedlock(native(), {ts}));
            switch (eno) {
            case 0:
                return true;
            case ETIMEDOUT:
                return false;
            case EOWNERDEAD: {
                    int eno2 = A0_SYSERR(a0_mtx_consistent(native()));
                    if (eno2 != 0) {
                        log.error("fail mutex lock[", eno, "] -> consistent[", eno2, "]");
                        return false;
                    }
                    int eno3 = A0_SYSERR(a0_mtx_unlock(native()));
                    if (eno3 != 0) {
                        log.error("fail mutex lock[", eno, "] -> unlock[", eno3, "]");
                        return false;
                    }
                }
                break; // loop again
            default:
                log.error("fail mutex lock[", eno, "]");
                return false;
            }
        }
    }

    bool try_lock() noexcept(false) {
        LIBIPC_LOG();
        if (!valid()) return false;
        int eno = A0_SYSERR(a0_mtx_timedlock(native(), {linux_::detail::make_timespec(0)}));
        switch (eno) {
        case 0:
            return true;
        case ETIMEDOUT:
            return false;
        case EOWNERDEAD: {
                int eno2 = A0_SYSERR(a0_mtx_consistent(native()));
                if (eno2 != 0) {
                    log.error("fail mutex try_lock[", eno, "] -> consistent[", eno2, "]");
                    break;
                }
                int eno3 = A0_SYSERR(a0_mtx_unlock(native()));
                if (eno3 != 0) {
                    log.error("fail mutex try_lock[", eno, "] -> unlock[", eno3, "]");
                    break;
                }
            }
            break;
        default:
            log.error("fail mutex try_lock[", eno, "]");
            break;
        }
        throw std::system_error{eno, std::system_category()};
    }

    bool unlock() noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        int eno = A0_SYSERR(a0_mtx_unlock(native()));
        if (eno != 0) {
            log.error("fail mutex unlock[", eno, "]");
            return false;
        }
        return true;
    }
};

class mutex {
    robust_mutex *mutex_ = nullptr;
    std::atomic<std::int32_t> *ref_ = nullptr;

    struct curr_prog {
        struct shm_data {
            robust_mutex mtx;
            std::atomic<std::int32_t> ref;

            struct init {
                char const *name;
            };
            shm_data(init arg)
                : mtx{}, ref{0} { mtx.open(arg.name); }
        };
        // Nodes are heap-allocated and referenced by pointer so that a live
        // node can be *moved* out of the by-name map into `orphans` (see
        // clear_storage) without being destroyed while open handles still hold
        // raw pointers into it.
        ipc::map<std::string, shm_data *> mutex_handles;
        // Nodes cleared via clear_storage() while still in use in-process; each
        // keeps its intact mapping + ref counter until its last local handle
        // closes. Drained in destroy_node().
        std::vector<shm_data *> orphans;
        std::mutex lock;

        static curr_prog &get() {
            static curr_prog info;
            return info;
        }

        ~curr_prog() {
            // Restore the exit-time cleanup that ~map<string, shm_data> used to
            // provide. Safe now that the central allocator is immortalized:
            // ~shm_data -> shm::release -> mem::$delete never touches a
            // destroyed allocator. See central_cache_allocator() for details.
            for (auto &kv : mutex_handles) delete kv.second;
            for (auto *p : orphans) delete p;
        }
    };

    // The node this handle acquired. Used to release by identity (not by name):
    // after clear_storage() orphans a node, a fresh open(name) creates a *new*
    // node under the same name, so a name-keyed release would corrupt the wrong
    // node's ref count. See context/refcount-aware-clear-storage-rfc.md.
    curr_prog::shm_data *node_ = nullptr;

    void acquire_mutex(char const *name) {
        if (name == nullptr) {
            return;
        }
        auto &info = curr_prog::get();
        LIBIPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
        auto it = info.mutex_handles.find(name);
        curr_prog::shm_data *node = nullptr;
        if (it == info.mutex_handles.end()) {
            node = new curr_prog::shm_data(curr_prog::shm_data::init{name});
            info.mutex_handles.emplace(name, node);
        } else {
            node = it->second;
        }
        node_  = node;
        mutex_ = &node->mtx;
        ref_   = &node->ref;
    }

    // Remove `node` from whichever container currently owns it (the by-name map
    // or the orphan list), by address, and destroy it. Must hold info.lock.
    static void destroy_node(curr_prog &info, curr_prog::shm_data *node) noexcept {
        for (auto it = info.mutex_handles.begin(); it != info.mutex_handles.end(); ++it) {
            if (it->second == node) {
                info.mutex_handles.erase(it);
                delete node;
                return;
            }
        }
        for (auto it = info.orphans.begin(); it != info.orphans.end(); ++it) {
            if (*it == node) {
                info.orphans.erase(it);
                delete node;
                return;
            }
        }
        // Not found: already removed by a concurrent path. Do not double-free.
    }

public:
    mutex() = default;
    ~mutex() = default;

    static void init() {
        // Avoid exception problems caused by static member initialization order.
        curr_prog::get();
    }

    a0_mtx_t const *native() const noexcept {
        return valid() ? mutex_->native() : nullptr;
    }

    a0_mtx_t *native() noexcept {
        return valid() ? mutex_->native() : nullptr;
    }

    bool valid() const noexcept {
        return (mutex_ != nullptr) && (ref_ != nullptr) && mutex_->valid();
    }

    bool open(char const *name) noexcept {
        close();
        acquire_mutex(name);
        if (!valid()) {
            return false;
        }
        ref_->fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    void close() noexcept {
        if ((mutex_ != nullptr) && (ref_ != nullptr) && (node_ != nullptr)) {
            if (mutex_->name() != nullptr) {
                auto &info = curr_prog::get();
                LIBIPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
                if (ref_->fetch_sub(1, std::memory_order_relaxed) <= 1) {
                    // Last local user: free the node (works whether it lives in
                    // the by-name map or the orphan list).
                    destroy_node(info, node_);
                }
            } else mutex_->close();
        }
        mutex_ = nullptr;
        ref_   = nullptr;
        node_  = nullptr;
    }

    void clear() noexcept {
        if ((mutex_ != nullptr) && (node_ != nullptr)) {
            if (mutex_->name() != nullptr) {
                auto &info = curr_prog::get();
                LIBIPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
                mutex_->clear();
                destroy_node(info, node_);
            } else mutex_->clear();
        }
        mutex_ = nullptr;
        ref_   = nullptr;
        node_  = nullptr;
    }

    // Ref-count-aware: if any handle in this process still holds `name` open,
    // orphan the node (keep its intact mapping + ref counter alive for those
    // handles) instead of destroying it; a subsequent open(name) then creates a
    // fresh node, exactly as a new opener in another process would. The global
    // name is always unlinked. See context/refcount-aware-clear-storage-rfc.md.
    static void clear_storage(char const *name) noexcept {
        LIBIPC_LOG();
        if (name == nullptr) return;
        {
            auto &info = curr_prog::get();
            LIBIPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
            auto it = info.mutex_handles.find(name);
            if (it != info.mutex_handles.end()) {
                auto *node = it->second;
                auto live = node->ref.load(std::memory_order_acquire);
                if (live > 0) {
                    log.warning("clear_storage('", name, "') with ", live,
                                " handle(s) still open in-process; orphaning the "
                                "segment (live handles keep a private stale mapping).");
                    info.orphans.push_back(node);
                    info.mutex_handles.erase(it);
                } else {
                    info.mutex_handles.erase(it);
                    delete node;
                }
            }
        }
        robust_mutex::clear_storage(name);
    }

    bool lock(std::uint64_t tm) noexcept {
        if (!valid()) return false;
        return mutex_->lock(tm);
    }

    bool try_lock() noexcept(false) {
        if (!valid()) return false;
        return mutex_->try_lock();
    }

    bool unlock() noexcept {
        if (!valid()) return false;
        return mutex_->unlock();
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
