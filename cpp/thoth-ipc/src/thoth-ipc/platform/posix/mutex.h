#pragma once

#include <cstring>
#include <cassert>
#include <cstdint>
#include <system_error>
#include <mutex>
#include <atomic>
#include <vector>

#include <pthread.h>

#include "thoth-ipc/platform/detail.h"
#include "thoth-ipc/imp/log.h"
#include "thoth-ipc/utility/scope_guard.h"
#include "thoth-ipc/mem/resource.h"
#include "thoth-ipc/shm.h"

#include "get_wait_time.h"

namespace thoth {
namespace detail {
namespace sync {

class mutex {
    thoth::shm::handle *shm_ = nullptr;
    std::atomic<std::int32_t> *ref_ = nullptr;
    pthread_mutex_t *mutex_ = nullptr;

    struct curr_prog {
        struct shm_data {
            thoth::shm::handle shm;
            std::atomic<std::int32_t> ref;

            struct init {
                char const *name;
                std::size_t size;
            };
            shm_data(init arg)
                : shm{arg.name, arg.size}, ref{0} {}
        };
        // Nodes are heap-allocated and referenced by pointer so that a live
        // node can be *moved* out of the by-name map into `orphans` (see
        // clear_storage) without being destroyed while open handles still hold
        // raw pointers into it.
        thoth::map<std::string, shm_data *> mutex_handles;
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

    pthread_mutex_t *acquire_mutex(char const *name) {
        if (name == nullptr) {
            return nullptr;
        }
        auto &info = curr_prog::get();
        THOTH_IPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
        auto it = info.mutex_handles.find(name);
        curr_prog::shm_data *node = nullptr;
        if (it == info.mutex_handles.end()) {
            node = new curr_prog::shm_data(
                curr_prog::shm_data::init{name, sizeof(pthread_mutex_t)});
            info.mutex_handles.emplace(name, node);
        } else {
            node = it->second;
        }
        node_ = node;
        shm_  = &node->shm;
        ref_  = &node->ref;
        return static_cast<pthread_mutex_t *>(shm_->get());
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

    static pthread_mutex_t const &zero_mem() {
        static const pthread_mutex_t tmp{};
        return tmp;
    }

public:
    mutex() = default;
    ~mutex() = default;

    static void init() {
        // Avoid exception problems caused by static member initialization order.
        zero_mem();
        curr_prog::get();
    }

    pthread_mutex_t const *native() const noexcept {
        return mutex_;
    }

    pthread_mutex_t *native() noexcept {
        return mutex_;
    }

    bool valid() const noexcept {
        return (shm_ != nullptr) && (ref_ != nullptr) && (mutex_ != nullptr)
            && (std::memcmp(&zero_mem(), mutex_, sizeof(pthread_mutex_t)) != 0);
    }

    bool open(char const *name) noexcept {
        THOTH_IPC_LOG();
        close();
        if ((mutex_ = acquire_mutex(name)) == nullptr) {
            return false;
        }
        auto self_ref = ref_->fetch_add(1, std::memory_order_relaxed);
        if (shm_->ref() > 1 || self_ref > 0) {
            return valid();
        }
        ::pthread_mutex_destroy(mutex_);
        auto finally = thoth::guard([this] { close(); }); // close when failed
        // init mutex
        int eno;
        pthread_mutexattr_t mutex_attr;
        if ((eno = ::pthread_mutexattr_init(&mutex_attr)) != 0) {
            log.error("fail pthread_mutexattr_init[", eno, "]");
            return false;
        }
        THOTH_IPC_UNUSED auto guard_mutex_attr = guard([&mutex_attr] { ::pthread_mutexattr_destroy(&mutex_attr); });
        if ((eno = ::pthread_mutexattr_setpshared(&mutex_attr, PTHREAD_PROCESS_SHARED)) != 0) {
            log.error("fail pthread_mutexattr_setpshared[", eno, "]");
            return false;
        }
        if ((eno = ::pthread_mutexattr_setrobust(&mutex_attr, PTHREAD_MUTEX_ROBUST)) != 0) {
            log.error("fail pthread_mutexattr_setrobust[", eno, "]");
            return false;
        }
        *mutex_ = PTHREAD_MUTEX_INITIALIZER;
        if ((eno = ::pthread_mutex_init(mutex_, &mutex_attr)) != 0) {
            log.error("fail pthread_mutex_init[", eno, "]");
            return false;
        }
        finally.dismiss();
        return valid();
    }

    void close() noexcept {
        THOTH_IPC_LOG();
        if ((ref_ != nullptr) && (shm_ != nullptr) && (mutex_ != nullptr) && (node_ != nullptr)) {
            if (shm_->name() != nullptr) {
                auto &info = curr_prog::get();
                THOTH_IPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
                auto self_ref = ref_->fetch_sub(1, std::memory_order_relaxed);
                if ((shm_->ref() <= 1) && (self_ref <= 1)) {
                    // Before destroying the mutex, try to unlock it.
                    // This is important for robust mutexes on FreeBSD, which maintain
                    // a per-thread robust list. If we destroy a mutex while it's locked
                    // or still in the robust list, FreeBSD may encounter dangling pointers
                    // later, leading to segfaults.
                    // Only unlock here (when we're the last reference) to avoid
                    // interfering with other threads that might be using the mutex.
                    ::pthread_mutex_unlock(mutex_);

                    int eno;
                    if ((eno = ::pthread_mutex_destroy(mutex_)) != 0) {
                        log.error("fail pthread_mutex_destroy[", eno, "]");
                    }
                    // Free the node (works whether it lives in the by-name map
                    // or the orphan list).
                    destroy_node(info, node_);
                }
            } else shm_->release();
        }
        shm_   = nullptr;
        ref_   = nullptr;
        mutex_ = nullptr;
        node_  = nullptr;
    }

    void clear() noexcept {
        THOTH_IPC_LOG();
        if ((shm_ != nullptr) && (mutex_ != nullptr) && (node_ != nullptr)) {
            if (shm_->name() != nullptr) {
                auto &info = curr_prog::get();
                THOTH_IPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
                // Unlock before destroying, same reasoning as in close()
                ::pthread_mutex_unlock(mutex_);

                int eno;
                if ((eno = ::pthread_mutex_destroy(mutex_)) != 0) {
                    log.error("fail pthread_mutex_destroy[", eno, "]");
                }
                shm_->clear();
                destroy_node(info, node_);
            } else shm_->clear();
        }
        shm_   = nullptr;
        ref_   = nullptr;
        mutex_ = nullptr;
        node_  = nullptr;
    }

    // Ref-count-aware: if any handle in this process still holds `name` open,
    // orphan the node (keep its intact mapping + ref counter alive for those
    // handles) instead of destroying it; a subsequent open(name) then creates a
    // fresh node, exactly as a new opener in another process would. The global
    // name is always unlinked. See context/refcount-aware-clear-storage-rfc.md.
    static void clear_storage(char const *name) noexcept {
        THOTH_IPC_LOG();
        if (name == nullptr) return;
        {
            auto &info = curr_prog::get();
            THOTH_IPC_UNUSED std::lock_guard<std::mutex> guard {info.lock};
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
        thoth::shm::handle::clear_storage(name);
    }

    bool lock(std::uint64_t tm) noexcept {
        THOTH_IPC_LOG();
        if (!valid()) return false;
        for (;;) {
            auto ts = posix_::detail::make_timespec(tm);
            int eno = (tm == invalid_value) 
                ? ::pthread_mutex_lock(mutex_) 
                : ::pthread_mutex_timedlock(mutex_, &ts);
            switch (eno) {
            case 0:
                return true;
            case ETIMEDOUT:
                return false;
            case EOWNERDEAD: {
                    // EOWNERDEAD means we have successfully acquired the lock,
                    // but the previous owner died. We need to make it consistent.
                    int eno2 = ::pthread_mutex_consistent(mutex_);
                    if (eno2 != 0) {
                        log.error("fail pthread_mutex_lock[", eno, "], pthread_mutex_consistent[", eno2, "]");
                        return false;
                    }
                    // After calling pthread_mutex_consistent(), the mutex is now in a
                    // consistent state and we hold the lock. Return success.
                    return true;
                }
            default:
                log.error("fail pthread_mutex_lock[", eno, "]");
                return false;
            }
        }
    }

    bool try_lock() noexcept(false) {
        THOTH_IPC_LOG();
        if (!valid()) return false;
        auto ts = posix_::detail::make_timespec(0);
        int eno = ::pthread_mutex_timedlock(mutex_, &ts);
        switch (eno) {
        case 0:
            return true;
        case ETIMEDOUT:
            return false;
        case EOWNERDEAD: {
                // EOWNERDEAD means we have successfully acquired the lock,
                // but the previous owner died. We need to make it consistent.
                int eno2 = ::pthread_mutex_consistent(mutex_);
                if (eno2 != 0) {
                    log.error("fail pthread_mutex_timedlock[", eno, "], pthread_mutex_consistent[", eno2, "]");
                    throw std::system_error{eno2, std::system_category()};
                }
                // After calling pthread_mutex_consistent(), the mutex is now in a
                // consistent state and we hold the lock. Return success.
                return true;
            }
        default:
            log.error("fail pthread_mutex_timedlock[", eno, "]");
            break;
        }
        throw std::system_error{eno, std::system_category()};
    }

    bool unlock() noexcept {
        THOTH_IPC_LOG();
        if (!valid()) return false;
        int eno;
        if ((eno = ::pthread_mutex_unlock(mutex_)) != 0) {
            log.error("fail pthread_mutex_unlock[", eno, "]");
            return false;
        }
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace thoth
