// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstdint>
#include <string>
#include <thread>
#include <chrono>

#include <fcntl.h>
#include <sys/stat.h>
#include <semaphore.h>
#include <errno.h>

#include "libipc/imp/log.h"
#include "libipc/shm.h"
#include "libipc/platform/posix/shm_name.h"

namespace ipc {
namespace detail {
namespace sync {

class semaphore {
    ipc::shm::handle shm_;
    sem_t *h_ = SEM_FAILED;
    std::string sem_name_;

public:
    semaphore() = default;
    ~semaphore() noexcept = default;

    void *native() const noexcept {
        return h_;
    }

    bool valid() const noexcept {
        return h_ != SEM_FAILED;
    }

    bool open(char const *name, std::uint32_t count) noexcept {
        LIBIPC_LOG();
        close();
        if (!shm_.acquire(name, 1)) {
            log.error("[open_semaphore] fail shm.acquire: ", name);
            return false;
        }
        // Use a separate namespace for semaphores to avoid conflicts with shm.
        std::string raw = std::string(name) + "_s";
        sem_name_ = ipc::posix_::detail::make_shm_name(raw.c_str());
        h_ = ::sem_open(sem_name_.c_str(), O_CREAT, 0666, static_cast<unsigned>(count));
        if (h_ == SEM_FAILED) {
            log.error("fail sem_open[", errno, "]: ", sem_name_);
            return false;
        }
        return true;
    }

    void close() noexcept {
        LIBIPC_LOG();
        if (!valid()) return;
        ::sem_close(h_);
        h_ = SEM_FAILED;
        if (!sem_name_.empty()) {
            ::sem_unlink(sem_name_.c_str());
            sem_name_.clear();
        }
        if (shm_.name() != nullptr)
            shm_.release();
    }

    void clear() noexcept {
        LIBIPC_LOG();
        if (valid()) {
            ::sem_close(h_);
            h_ = SEM_FAILED;
        }
        if (!sem_name_.empty()) {
            ::sem_unlink(sem_name_.c_str());
            sem_name_.clear();
        }
        shm_.clear();
    }

    static void clear_storage(char const *name) noexcept {
        std::string raw = std::string(name) + "_s";
        std::string sem_name = ipc::posix_::detail::make_shm_name(raw.c_str());
        ::sem_unlink(sem_name.c_str());
        ipc::shm::handle::clear_storage(name);
    }

    bool wait(std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        if (tm == invalid_value) {
            if (::sem_wait(h_) != 0) {
                log.error("fail sem_wait[", errno, "]");
                return false;
            }
            return true;
        }
        // macOS lacks sem_timedwait — emulate with polling.
        auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::milliseconds(tm);
        for (;;) {
            if (::sem_trywait(h_) == 0) return true;
            if (errno != EAGAIN) {
                log.error("fail sem_trywait[", errno, "]");
                return false;
            }
            if (std::chrono::steady_clock::now() >= deadline) return false;
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    }

    bool post(std::uint32_t count) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        for (std::uint32_t i = 0; i < count; ++i) {
            if (::sem_post(h_) != 0) {
                log.error("fail sem_post[", errno, "]");
                return false;
            }
        }
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
