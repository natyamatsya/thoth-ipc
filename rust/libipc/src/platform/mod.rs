// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#[cfg(unix)]
pub mod posix;

#[cfg(windows)]
pub mod windows;

// Re-export the platform-specific implementations under a uniform name.

#[cfg(unix)]
pub use posix::PlatformShm;
#[cfg(unix)]
pub use posix::PlatformMutex;

#[cfg(windows)]
pub use windows::PlatformShm;
#[cfg(windows)]
pub use windows::PlatformMutex;
