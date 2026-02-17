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
