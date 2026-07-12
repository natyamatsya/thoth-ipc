// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Pure Rust implementation of cpp-ipc shared memory and named mutex primitives.
// Binary-compatible with the C++ libipc library — same memory layout, same naming
// conventions, same POSIX/Win32 syscalls.

pub mod shm_name;

mod platform;

mod shm;
pub use shm::{ShmHandle, ShmOpenMode};

mod mutex;
pub use mutex::IpcMutex;

mod scoped_access;
pub use scoped_access::ScopedAccess;

mod spin_lock;
pub use spin_lock::SpinLock;

mod rw_lock;
pub use rw_lock::RwLock;

mod semaphore;
pub use semaphore::IpcSemaphore;

mod condition;
pub use condition::IpcCondition;

mod sync_abi;

pub mod buffer;
pub use buffer::IpcBuffer;

pub mod waiter;
pub use waiter::Waiter;

pub mod circ;

pub(crate) mod chunk_storage;

#[cfg(feature = "notify")]
pub mod notify;

#[cfg(feature = "async-tokio")]
pub mod async_recv;

pub mod channel;
pub use channel::{Channel, Mode, Route};

pub mod proto;

pub mod mem;

/// Current `errno` on Unix, portable across macOS (`__error`) and glibc/musl
/// (`__errno_location`). The two spellings resolve to different libc symbols, so
/// the macOS name cannot be used unconditionally on Linux.
#[cfg(unix)]
#[inline]
pub(crate) fn unix_errno() -> i32 {
    #[cfg(target_os = "macos")]
    {
        unsafe { *libc::__error() }
    }
    #[cfg(not(target_os = "macos"))]
    {
        unsafe { *libc::__errno_location() }
    }
}
