#pragma once

#include <cstddef>
#include <cstdint>

#include "thoth-ipc/imp/export.h"

namespace thoth {
namespace shm {

using id_t = void*;

// Named (rather than anonymous) so the enumerators have external linkage and
// can be re-exported by the thoth.ipc module (modules/thoth.ipc.cppm).
enum open_mode : unsigned {
    create = 0x01,
    open   = 0x02
};

THOTH_IPC_EXPORT id_t         acquire(char const * name, std::size_t size, unsigned mode = create | open);
THOTH_IPC_EXPORT void *       get_mem(id_t id, std::size_t * size);

// Release shared memory resource and clean up disk file if reference count reaches zero.
// This function decrements the reference counter. When the counter reaches zero, it:
// 1. Unmaps the shared memory region
// 2. Removes the backing file from disk (shm_unlink on POSIX)
// 3. Frees the id structure
// After calling this function, the id becomes invalid and must not be used again.
// Returns: The reference count before decrement, or -1 on error.
THOTH_IPC_EXPORT std::int32_t release(id_t id) noexcept;

// Release shared memory resource and force cleanup of disk file.
// This function calls release(id) internally, then unconditionally attempts to
// remove the backing file. WARNING: Do NOT call this after release(id) on the
// same id, as the id is already freed by release(). Use this function alone,
// not in combination with release().
// Typical use case: Force cleanup when you want to ensure the disk file is removed
// regardless of reference count state.
THOTH_IPC_EXPORT void         remove (id_t id) noexcept;

// Remove shared memory backing file by name.
// This function only removes the disk file and does not affect any active memory
// mappings or id structures. Use this for cleanup of orphaned files or for explicit
// file removal without affecting runtime resources.
// Safe to call at any time, even if shared memory is still in use elsewhere.
THOTH_IPC_EXPORT void         remove (char const * name) noexcept;

THOTH_IPC_EXPORT std::int32_t get_ref(id_t id);
THOTH_IPC_EXPORT void sub_ref(id_t id);

class THOTH_IPC_EXPORT handle {
public:
    handle();
    handle(char const * name, std::size_t size, unsigned mode = create | open);
    handle(handle&& rhs);

    ~handle();

    void swap(handle& rhs);
    handle& operator=(handle rhs);

    bool         valid() const noexcept;
    std::size_t  size () const noexcept;
    char const * name () const noexcept;

    std::int32_t ref() const noexcept;
    void sub_ref() noexcept;

    bool acquire(char const * name, std::size_t size, unsigned mode = create | open);
    std::int32_t release();

    // Whether this platform can grow an existing shared memory object
    // (Linux only: ftruncate enlarges POSIX shm; macOS allows exactly one
    // sizing ftruncate per object, Windows sections are fixed at creation).
    // Callers must branch on this instead of calling grow() and handling
    // the failure.
    static bool can_grow() noexcept;

    // Grow the shared memory object to at least `size` user-visible bytes.
    // Returns false on error and where can_grow() is false.
    bool grow(std::size_t size);

    // Clean the handle file.
    void clear() noexcept;
    static void clear_storage(char const * name) noexcept;

    void* get() const;

    void attach(id_t);
    id_t detach();

private:
    class handle_;
    handle_* p_;
};

} // namespace shm
} // namespace thoth

