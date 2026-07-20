/// \file thoth.ipc.cppm
/// \brief C++20 named module for the always-on thoth-ipc core surface.
///
/// This is a thin wrapper: the existing headers are included in the global
/// module fragment and the public names are re-exported via using-declarations
/// (the sqlpp23 approach). The library itself stays include-first; importers
/// link the `thoth_ipc_module` target and write `import thoth.ipc;`.
///
/// Modules cannot export macros. Consumers who need THOTH_IPC_LOG,
/// THOTH_IPC_SCOPE_EXIT, THOTH_IPC_EXPORT or the detect_plat.h macro set must
/// keep including those headers — and every #include must precede the import
/// in a TU (GCC PR114795).
///
/// Not covered here (header-only by design or opt-in layers): async_recv.h /
/// execution/*, proto/*, mem/*, concur/*, imp/*, abi_generated.hpp.
module;

// Global module fragment: every declaration referenced by the exports below.
// ipc.h transitively pulls imp/export.h, imp/detect_plat.h, def.h, buffer.h,
// shm.h and <string>; on MSVC rw_lock.h pulls <windows.h> — safe here, since
// the GMF ends before the module purview begins.
#include "thoth-ipc/ipc.h"
#include "thoth-ipc/mutex.h"
#include "thoth-ipc/semaphore.h"
#include "thoth-ipc/condition.h"
#include "thoth-ipc/rw_lock.h"

export module thoth.ipc;

export namespace thoth {

// --- def.h ---
using ::thoth::byte_t;
using ::thoth::uint;
using ::thoth::uint_t;
using ::thoth::constants;
using ::thoth::invalid_value;
using ::thoth::default_timeout;
using ::thoth::size_constants;
using ::thoth::central_cache_default_size;
using ::thoth::data_length;
using ::thoth::large_msg_limit;
using ::thoth::large_msg_align;
using ::thoth::large_msg_cache;
using ::thoth::relat;
using ::thoth::trans;
using ::thoth::wr;
using ::thoth::relat_trait;
using ::thoth::prefix;

// --- buffer.h ---
// operator== / operator!= are hidden friends (declared in-class only); they
// are reachable via ADL through the exported `buffer` and must not (and
// cannot) be named in a using-declaration here.
using ::thoth::buffer;

// --- ipc.h ---
using ::thoth::handle_t;
using ::thoth::buff_t;
using ::thoth::wait_handle_t;
using ::thoth::connect_mode;
using ::thoth::sender;
using ::thoth::receiver;
using ::thoth::chan_impl;
using ::thoth::chan_wrapper;
using ::thoth::chan;
using ::thoth::route;
using ::thoth::channel;

// Explicitly `inline` in the header, so (since C++17) it has external
// linkage and can be re-exported like everything else.
using ::thoth::invalid_wait_handle;

// --- rw_lock.h ---
using ::thoth::yield;
using ::thoth::sleep;
using ::thoth::spin_lock;
using ::thoth::rw_lock;

} // export namespace thoth

export namespace thoth::sync {

using ::thoth::sync::mutex;      // mutex.h
using ::thoth::sync::semaphore;  // semaphore.h
using ::thoth::sync::condition;  // condition.h

} // export namespace thoth::sync

export namespace thoth::shm {

// --- shm.h ---
using ::thoth::shm::id_t;
using ::thoth::shm::open_mode;
using ::thoth::shm::create;
using ::thoth::shm::open;
using ::thoth::shm::acquire;
using ::thoth::shm::get_mem;
using ::thoth::shm::release;
using ::thoth::shm::remove;      // both overloads
using ::thoth::shm::get_ref;
using ::thoth::shm::sub_ref;
using ::thoth::shm::handle;

} // export namespace thoth::shm
