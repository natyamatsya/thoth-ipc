// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

#[cfg(unix)]
pub mod posix;

#[cfg(target_os = "macos")]
pub mod apple;

// Linux/Android: a native Rust port of the alephzero (a0) robust PI futex
// mutex/condition the C++ Linux backend runs (sync ABI backend 5 = linux_a0).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub mod linux;

#[cfg(windows)]
pub mod windows;

// Re-export the platform-specific implementations under a uniform name.

#[cfg(unix)]
pub use posix::PlatformShm;

// On macOS use the ulock-based mutex (binary-compatible with C++ apple/mutex.h).
// On Linux/Android use the a0 futex mutex (binary-compatible with C++
// linux/mutex.h). On other Unix platforms (FreeBSD, ...) use the pthread mutex
// (C++ posix/mutex.h).
#[cfg(target_os = "macos")]
pub use apple::PlatformMutex;
#[cfg(any(target_os = "linux", target_os = "android"))]
pub use linux::PlatformMutex;
#[cfg(all(
    unix,
    not(any(target_os = "macos", target_os = "linux", target_os = "android"))
))]
pub use posix::PlatformMutex;

#[cfg(windows)]
pub use windows::PlatformMutex;
#[cfg(windows)]
pub use windows::PlatformShm;
