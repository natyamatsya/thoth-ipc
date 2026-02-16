// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include <atomic>
#include <string>
#include <utility>
#include <cstring>

#include "libipc/shm.h"
#include "libipc/def.h"

#include "libipc/imp/log.h"
#include "libipc/mem/resource.h"
#include "libipc/mem/new.h"

#include "shm_name.h"

#if defined(LIBIPC_USE_FILE_SHM)
#include <string>
namespace {

constexpr char const file_shm_dir[] = "/tmp/cpp-ipc";

inline std::string make_file_path(char const *name) {
    std::string path = file_shm_dir;
    path += '/';
    // Replace '/' in name with '_' to flatten into a single directory
    for (char const *p = name; *p; ++p)
        path += (*p == '/') ? '_' : *p;
    return path;
}

inline void ensure_dir() {
    ::mkdir(file_shm_dir, 0777);
}

inline int file_shm_open(char const *path, int flags, mode_t mode) {
    ensure_dir();
    return ::open(path, flags, mode);
}

inline int file_shm_unlink(char const *path) {
    return ::unlink(path);
}

} // internal-linkage
#endif

namespace {

struct info_t {
    std::atomic<std::int32_t> acc_;
};

struct id_info_t {
    int         fd_   = -1;
    void*       mem_  = nullptr;
    std::size_t size_ = 0;
    std::string name_;
};

constexpr std::size_t calc_size(std::size_t size) {
    return ((((size - 1) / alignof(info_t)) + 1) * alignof(info_t)) + sizeof(info_t);
}

inline auto& acc_of(void* mem, std::size_t size) {
    return reinterpret_cast<info_t*>(static_cast<ipc::byte_t*>(mem) + size - sizeof(info_t))->acc_;
}

} // internal-linkage

namespace ipc {
namespace shm {

id_t acquire(char const * name, std::size_t size, unsigned mode) {
    LIBIPC_LOG();
    if (!is_valid_string(name)) {
        log.error("fail acquire: name is empty");
        return nullptr;
    }
#if defined(LIBIPC_USE_FILE_SHM)
    std::string op_name = make_file_path(name);
#else
    std::string op_name = ipc::posix_::detail::make_shm_name(name);
#endif
    // Open the object for read-write access.
    int flag = O_RDWR;
    switch (mode) {
    case open:
#if defined(LIBIPC_OS_APPLE) && !defined(LIBIPC_USE_FILE_SHM)
        // On macOS, fstat returns page-rounded sizes which would place the
        // ref counter at the wrong offset. Keep the caller's size if provided
        // so get_mem uses calc_size consistently with the creator.
        break;
#else
        size = 0;
        break;
#endif
    // The check for the existence of the object, 
    // and its creation if it does not exist, are performed atomically.
    case create:
        flag |= O_CREAT | O_EXCL;
        break;
    // Create the shared memory object if it does not exist.
    default:
        flag |= O_CREAT;
        break;
    }
    constexpr auto perms = S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH;
#if defined(LIBIPC_USE_FILE_SHM)
    int fd = file_shm_open(op_name.c_str(), flag, perms);
#else
    int fd = ::shm_open(op_name.c_str(), flag, perms);
#endif
    if (fd == -1) {
        // only open shm not log error when file not exist
        if (open != mode || ENOENT != errno) {
            log.error("fail shm_open[", errno, "]: ", op_name);
        }
        return nullptr;
    }
    ::fchmod(fd, perms);
    auto ii = mem::$new<id_info_t>();
    ii->fd_   = fd;
    ii->size_ = size;
    ii->name_ = std::move(op_name);
    return ii;
}

std::int32_t get_ref(id_t id) {
    if (id == nullptr) {
        return 0;
    }
    auto ii = static_cast<id_info_t*>(id);
    if (ii->mem_ == nullptr || ii->size_ == 0) {
        return 0;
    }
    return acc_of(ii->mem_, ii->size_).load(std::memory_order_acquire);
}

void sub_ref(id_t id) {
    LIBIPC_LOG();
    if (id == nullptr) {
        log.error("fail sub_ref: invalid id (null)");
        return;
    }
    auto ii = static_cast<id_info_t*>(id);
    if (ii->mem_ == nullptr || ii->size_ == 0) {
        log.error("fail sub_ref: invalid id (mem = ", ii->mem_, ", size = ", ii->size_, ")");
        return;
    }
    acc_of(ii->mem_, ii->size_).fetch_sub(1, std::memory_order_acq_rel);
}

void * get_mem(id_t id, std::size_t * size) {
    LIBIPC_LOG();
    if (id == nullptr) {
        log.error("fail get_mem: invalid id (null)");
        return nullptr;
    }
    auto ii = static_cast<id_info_t*>(id);
    if (ii->mem_ != nullptr) {
        if (size != nullptr) *size = ii->size_;
        return ii->mem_;
    }
    int fd = ii->fd_;
    if (fd == -1) {
        log.error("fail get_mem: invalid id (fd = -1)");
        return nullptr;
    }
    if (ii->size_ == 0) {
        struct stat st;
        if (::fstat(fd, &st) != 0) {
            log.error("fail fstat[", errno, "]: ", ii->name_, ", size = ", ii->size_);
            return nullptr;
        }
        ii->size_ = static_cast<std::size_t>(st.st_size);
        if ((ii->size_ <= sizeof(info_t)) || (ii->size_ % sizeof(info_t))) {
            log.error("fail get_mem: ", ii->name_, ", invalid size = ", ii->size_);
            return nullptr;
        }
    }
    else {
        ii->size_ = calc_size(ii->size_);
        if (::ftruncate(fd, static_cast<off_t>(ii->size_)) != 0) {
#if defined(LIBIPC_OS_APPLE)
            // macOS returns EINVAL when ftruncate is called on an already-sized
            // shm object. Check if the existing size is compatible.
            if (errno == EINVAL) {
                struct stat st;
                if (::fstat(fd, &st) == 0
                    && static_cast<std::size_t>(st.st_size) >= ii->size_) {
                    goto ftruncate_ok; // existing object already has the correct size
                }
                // Size mismatch — stale object from a previous run.
                // Unlink it, recreate, and retry ftruncate.
                ::close(fd);
                ii->fd_ = -1;
#if defined(LIBIPC_USE_FILE_SHM)
                file_shm_unlink(ii->name_.c_str());
                fd = file_shm_open(ii->name_.c_str(), O_RDWR | O_CREAT,
                                   S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH);
#else
                ::shm_unlink(ii->name_.c_str());
                fd = ::shm_open(ii->name_.c_str(), O_RDWR | O_CREAT, 
                                S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH);
#endif
                if (fd == -1) {
                    log.error("fail shm_open (recreate)[", errno, "]: ", ii->name_);
                    return nullptr;
                }
                ii->fd_ = fd;
                if (::ftruncate(fd, static_cast<off_t>(ii->size_)) != 0) {
                    log.error("fail ftruncate (retry)[", errno, "]: ", ii->name_, ", size = ", ii->size_);
                    return nullptr;
                }
            } else
#endif
            {
                log.error("fail ftruncate[", errno, "]: ", ii->name_, ", size = ", ii->size_);
                return nullptr;
            }
        }
#if defined(LIBIPC_OS_APPLE)
        ftruncate_ok:
#endif
        (void)0;
    }
    void* mem = ::mmap(nullptr, ii->size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem == MAP_FAILED) {
        log.error("fail mmap[", errno, "]: ", ii->name_, ", size = ", ii->size_);
        return nullptr;
    }
    ::close(fd);
    ii->fd_  = -1;
    ii->mem_ = mem;
    if (size != nullptr) *size = ii->size_;
    acc_of(mem, ii->size_).fetch_add(1, std::memory_order_release);
    return mem;
}

std::int32_t release(id_t id) noexcept {
    LIBIPC_LOG();
    if (id == nullptr) {
        log.error("fail release: invalid id (null)");
        return -1;
    }
    std::int32_t ret = -1;
    auto ii = static_cast<id_info_t*>(id);
    if (ii->mem_ == nullptr || ii->size_ == 0) {
        log.error("fail release: invalid id (mem = ", ii->mem_, ", size = ", ii->size_, "), name = ", ii->name_);
    }
    else if ((ret = acc_of(ii->mem_, ii->size_).fetch_sub(1, std::memory_order_acq_rel)) <= 1) {
        ::munmap(ii->mem_, ii->size_);
        if (!ii->name_.empty()) {
#if defined(LIBIPC_USE_FILE_SHM)
            int unlink_ret = file_shm_unlink(ii->name_.c_str());
#else
            int unlink_ret = ::shm_unlink(ii->name_.c_str());
#endif
            if (unlink_ret == -1) {
                log.error("fail shm_unlink[", errno, "]: ", ii->name_);
            }
        }
    }
    else ::munmap(ii->mem_, ii->size_);
    mem::$delete(ii);
    return ret;
}

void remove(id_t id) noexcept {
    LIBIPC_LOG();
    if (id == nullptr) {
        log.error("fail remove: invalid id (null)");
        return;
    }
    auto ii = static_cast<id_info_t*>(id);
    auto name = std::move(ii->name_);
    release(id);
    if (!name.empty()) {
#if defined(LIBIPC_USE_FILE_SHM)
        int unlink_ret = file_shm_unlink(name.c_str());
#else
        int unlink_ret = ::shm_unlink(name.c_str());
#endif
        if (unlink_ret == -1) {
            log.error("fail shm_unlink[", errno, "]: ", name);
        }
    }
}

void remove(char const * name) noexcept {
    LIBIPC_LOG();
    if (!is_valid_string(name)) {
        log.error("fail remove: name is empty");
        return;
    }
#if defined(LIBIPC_USE_FILE_SHM)
    std::string op_name = make_file_path(name);
    int unlink_ret = file_shm_unlink(op_name.c_str());
#else
    std::string op_name = ipc::posix_::detail::make_shm_name(name);
    int unlink_ret = ::shm_unlink(op_name.c_str());
#endif
    if (unlink_ret == -1) {
        log.error("fail shm_unlink[", errno, "]: ", op_name);
    }
}

} // namespace shm
} // namespace ipc
