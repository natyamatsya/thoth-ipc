#pragma once

#include <atomic>
#include <cstdint>
#include <limits>
#include <string>
#include <thread>

#include "libipc/imp/detect_plat.h"
#include "libipc/imp/log.h"
#include "libipc/mem/resource.h"
#include "libipc/shm.h"

#if defined(LIBIPC_OS_LINUX)
#include "a0/mtx.h"
#elif defined(LIBIPC_OS_QNX) || defined(LIBIPC_OS_FREEBSD) || defined(LIBIPC_OS_APPLE)
#include <pthread.h>
#endif

namespace ipc {
namespace detail {
namespace sync_abi {

enum : std::uint32_t {
    sync_abi_magic            = 0x4C495341u, // "LISA"
    sync_abi_init_in_progress = (std::numeric_limits<std::uint32_t>::max)(),
    sync_abi_version_major    = 1u,
    sync_abi_version_minor    = 0u,
};

enum class primitive_kind : std::uint32_t {
    mutex     = 1u,
    condition = 2u,
};

struct stamp_t {
    std::atomic<std::uint32_t> magic             {0};
    std::atomic<std::uint32_t> abi_version_major {0};
    std::atomic<std::uint32_t> abi_version_minor {0};
    std::atomic<std::uint32_t> backend_id        {0};
    std::atomic<std::uint32_t> primitive_id      {0};
    std::atomic<std::uint32_t> payload_size      {0};
};

struct expected_t {
    std::uint32_t abi_version_major;
    std::uint32_t abi_version_minor;
    std::uint32_t backend_id;
    std::uint32_t primitive_id;
    std::uint32_t payload_size;
};

inline char const *kind_name(primitive_kind const kind) noexcept {
    switch (kind) {
    case primitive_kind::mutex:
        return "mutex";
    case primitive_kind::condition:
        return "condition";
    }
    return "unknown";
}

inline char const *suffix_of(primitive_kind const kind) noexcept {
    switch (kind) {
    case primitive_kind::mutex:
        return "__libipc_sync_abi_mutex";
    case primitive_kind::condition:
        return "__libipc_sync_abi_condition";
    }
    return "__libipc_sync_abi_unknown";
}

inline std::string sidecar_name(char const *name, primitive_kind const kind) {
    return std::string{name} + suffix_of(kind);
}

inline std::uint32_t backend_id() noexcept {
#if defined(LIBIPC_OS_APPLE)
# if defined(LIBIPC_APPLE_APP_STORE_SAFE)
    return 3u; // apple_mach
# else
    return 2u; // apple_ulock
# endif
#elif defined(LIBIPC_OS_WIN)
    return 4u; // win32
#elif defined(LIBIPC_OS_LINUX)
    return 5u; // linux_a0
#else
    return 1u; // posix_pthread
#endif
}

inline std::uint32_t mutex_payload_size() noexcept {
#if defined(LIBIPC_OS_APPLE)
    struct mutex_state_layout {
        std::atomic<std::uint32_t> state;
        std::atomic<std::int32_t> holder;
    };
# if defined(LIBIPC_APPLE_APP_STORE_SAFE)
    return static_cast<std::uint32_t>(
        sizeof(mutex_state_layout) + sizeof(std::atomic<std::int32_t>));
# else
    return static_cast<std::uint32_t>(sizeof(mutex_state_layout));
# endif
#elif defined(LIBIPC_OS_WIN)
    return 0u;
#elif defined(LIBIPC_OS_LINUX)
    return static_cast<std::uint32_t>(sizeof(a0_mtx_t));
#else
    return static_cast<std::uint32_t>(sizeof(pthread_mutex_t));
#endif
}

inline std::uint32_t condition_payload_size() noexcept {
#if defined(LIBIPC_OS_APPLE)
    struct condition_state_layout {
        std::atomic<std::uint32_t> seq;
        std::atomic<std::int32_t> waiters;
    };
    return static_cast<std::uint32_t>(sizeof(condition_state_layout));
#elif defined(LIBIPC_OS_WIN)
    return 0u;
#elif defined(LIBIPC_OS_LINUX)
    return static_cast<std::uint32_t>(sizeof(a0_cnd_t));
#else
    return static_cast<std::uint32_t>(sizeof(pthread_cond_t));
#endif
}

inline expected_t expected_of(primitive_kind const kind) noexcept {
    return expected_t {
        sync_abi_version_major,
        sync_abi_version_minor,
        backend_id(),
        static_cast<std::uint32_t>(kind),
        kind == primitive_kind::mutex ? mutex_payload_size() : condition_payload_size(),
    };
}

inline bool validate(stamp_t const *stamp, expected_t const &expected, primitive_kind const kind) noexcept {
    LIBIPC_LOG();
    auto const actual_major = stamp->abi_version_major.load(std::memory_order_acquire);
    auto const actual_minor = stamp->abi_version_minor.load(std::memory_order_acquire);
    auto const actual_backend = stamp->backend_id.load(std::memory_order_acquire);
    auto const actual_primitive = stamp->primitive_id.load(std::memory_order_acquire);
    auto const actual_payload = stamp->payload_size.load(std::memory_order_acquire);

    if (actual_major == expected.abi_version_major
        && actual_minor == expected.abi_version_minor
        && actual_backend == expected.backend_id
        && actual_primitive == expected.primitive_id
        && actual_payload == expected.payload_size)
        return true;

    log.error("sync ABI mismatch for ", kind_name(kind),
              ": expected major.minor=", expected.abi_version_major, ".", expected.abi_version_minor,
              ", backend=", expected.backend_id,
              ", primitive=", expected.primitive_id,
              ", payload=", expected.payload_size,
              " but found major.minor=", actual_major, ".", actual_minor,
              ", backend=", actual_backend,
              ", primitive=", actual_primitive,
              ", payload=", actual_payload);
    return false;
}

inline bool init_or_validate(stamp_t *stamp, expected_t const &expected, primitive_kind const kind) noexcept {
    LIBIPC_LOG();
    for (;;) {
        auto const magic = stamp->magic.load(std::memory_order_acquire);
        if (magic == sync_abi_magic)
            return validate(stamp, expected, kind);

        if (magic == sync_abi_init_in_progress) {
            std::this_thread::yield();
            continue;
        }

        if (magic == 0u) {
            auto expected_magic = std::uint32_t{0};
            if (!stamp->magic.compare_exchange_strong(expected_magic,
                                                      sync_abi_init_in_progress,
                                                      std::memory_order_acq_rel,
                                                      std::memory_order_acquire))
                continue;

            stamp->abi_version_major.store(expected.abi_version_major, std::memory_order_relaxed);
            stamp->abi_version_minor.store(expected.abi_version_minor, std::memory_order_relaxed);
            stamp->backend_id.store(expected.backend_id, std::memory_order_relaxed);
            stamp->primitive_id.store(expected.primitive_id, std::memory_order_relaxed);
            stamp->payload_size.store(expected.payload_size, std::memory_order_relaxed);
            stamp->magic.store(sync_abi_magic, std::memory_order_release);
            return true;
        }

        log.error("sync ABI stamp magic mismatch for ", kind_name(kind),
                  ": expected ", static_cast<std::uint32_t>(sync_abi_magic),
                  ", found ", static_cast<std::uint32_t>(magic));
        return false;
    }
}

class guard {
    ipc::shm::handle shm_;

    bool ensure(char const *name, primitive_kind const kind) noexcept {
        LIBIPC_LOG();
        close();
        if (!is_valid_string(name)) {
            log.error("fail sync ABI open: name is empty");
            return false;
        }

        auto const meta_name = sidecar_name(name, kind);
        if (!shm_.acquire(meta_name.c_str(), sizeof(stamp_t))) {
            log.error("fail sync ABI shm.acquire: ", meta_name);
            return false;
        }

        auto *stamp = static_cast<stamp_t *>(shm_.get());
        if (stamp == nullptr) {
            log.error("fail sync ABI get_mem: ", meta_name);
            shm_.release();
            return false;
        }

        auto const expected = expected_of(kind);
        if (init_or_validate(stamp, expected, kind)) return true;

        shm_.release();
        return false;
    }

    static void clear_storage(char const *name, primitive_kind const kind) noexcept {
        if (!is_valid_string(name)) return;
        auto const meta_name = sidecar_name(name, kind);
        ipc::shm::handle::clear_storage(meta_name.c_str());
    }

public:
    bool open_mutex(char const *name) noexcept {
        return ensure(name, primitive_kind::mutex);
    }

    bool open_condition(char const *name) noexcept {
        return ensure(name, primitive_kind::condition);
    }

    void close() noexcept {
        shm_.release();
    }

    void clear() noexcept {
        shm_.clear();
    }

    static void clear_mutex_storage(char const *name) noexcept {
        clear_storage(name, primitive_kind::mutex);
    }

    static void clear_condition_storage(char const *name) noexcept {
        clear_storage(name, primitive_kind::condition);
    }
};

} // namespace sync_abi
} // namespace detail
} // namespace ipc
