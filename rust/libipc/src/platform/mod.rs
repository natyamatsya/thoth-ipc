// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#[cfg(unix)]
pub mod posix;

#[cfg(target_os = "macos")]
pub mod apple;

#[cfg(windows)]
pub mod windows;

// Re-export the platform-specific implementations under a uniform name.

#[cfg(unix)]
pub use posix::PlatformShm;

// On macOS use the ulock-based mutex (binary-compatible with C++ apple/mutex.h).
// On other Unix platforms use the pthread-based mutex.
#[cfg(target_os = "macos")]
pub use apple::PlatformMutex;
#[cfg(all(unix, not(target_os = "macos")))]
pub use posix::PlatformMutex;

#[cfg(windows)]
pub use windows::PlatformMutex;
#[cfg(windows)]
pub use windows::PlatformShm;
