
#include <mutex>
#include <array>
#include <cstddef>

#include "thoth-ipc/def.h"
#include "thoth-ipc/imp/detect_plat.h"
#include "thoth-ipc/imp/byte.h"
#include "thoth-ipc/mem/bytes_allocator.h"
#include "thoth-ipc/mem/memory_resource.h"

namespace thoth {
namespace mem {

class thread_safe_resource : public monotonic_buffer_resource {
public:
  thread_safe_resource(span<byte> buffer) noexcept
      : monotonic_buffer_resource(buffer) {}

  ~thread_safe_resource() noexcept {
    THOTH_IPC_UNUSED std::lock_guard<std::mutex> lock(mutex_);
    monotonic_buffer_resource::release();
  }

  void *allocate(std::size_t bytes, std::size_t alignment) noexcept {
    THOTH_IPC_UNUSED std::lock_guard<std::mutex> lock(mutex_);
    return monotonic_buffer_resource::allocate(bytes, alignment);
  }

  void deallocate(void *p, std::size_t bytes, std::size_t alignment) noexcept {
    THOTH_IPC_UNUSED std::lock_guard<std::mutex> lock(mutex_);
    monotonic_buffer_resource::deallocate(p, bytes, alignment);
  }

private:
  std::mutex mutex_;
};

bytes_allocator &central_cache_allocator() noexcept {
  // Intentionally leaked (never destroyed). Thread-local block caches flush back
  // here from ~block_pool during thread exit, which can occur *after* a plain
  // function-local static would have been destroyed at process teardown. Destroying
  // `res` (and its `mutex_`) early let a late-joining thread lock a destroyed mutex
  // -> pthread_mutex_lock EINVAL -> std::mutex::lock throws from a noexcept dtor ->
  // std::terminate. Leaking keeps the mutex alive until _exit; the OS reclaims the
  // few KB. See release() in central_cache_pool.h.
  static auto *buf = new std::array<byte, central_cache_default_size>();
  static auto *res = new thread_safe_resource(*buf);
  static auto *a   = new bytes_allocator(res);
  return *a;
}

} // namespace mem
} // namespace thoth
