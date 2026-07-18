#pragma once

#include <cstdint>  // std::uint64_t

#include "thoth-ipc/imp/export.h"
#include "thoth-ipc/def.h"
#include "thoth-ipc/mutex.h"

namespace thoth {
namespace sync {

class THOTH_IPC_EXPORT condition {
    condition(condition const &) = delete;
    condition &operator=(condition const &) = delete;

public:
    condition();
    explicit condition(char const *name);
    ~condition();

    void const *native() const noexcept;
    void *native() noexcept;

    bool valid() const noexcept;

    bool open(char const *name) noexcept;
    void close() noexcept;

    void clear() noexcept;
    static void clear_storage(char const * name) noexcept;

    bool wait(thoth::sync::mutex &mtx, std::uint64_t tm = thoth::invalid_value) noexcept;
    bool notify(thoth::sync::mutex &mtx) noexcept;
    bool broadcast(thoth::sync::mutex &mtx) noexcept;

private:
    class condition_;
    condition_* p_;
};

} // namespace sync
} // namespace thoth
