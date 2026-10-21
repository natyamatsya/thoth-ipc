// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// A timestamp on C++'s `std::chrono::steady_clock`, for shared-memory fields
// that C++ and Rust processes both write and compare (e.g. a heartbeat).
// `std::time::Instant` is opaque and `SystemTime` is the wall clock, so neither
// can be shared with a C++ peer; this reads the same clock the C++ standard
// library does on each platform.

/// Nanoseconds since the `std::chrono::steady_clock` epoch of this platform:
/// CLOCK_MONOTONIC (libstdc++/libc++ on Linux and other Unix), CLOCK_UPTIME_RAW
/// (libc++ on Apple), QueryPerformanceCounter scaled as MSVC does (Windows).
pub fn steady_clock_ns() -> u64 {
    imp::now_ns()
}

#[cfg(unix)]
mod imp {
    #[cfg(target_vendor = "apple")]
    const CLOCK: libc::clockid_t = libc::CLOCK_UPTIME_RAW;
    #[cfg(not(target_vendor = "apple"))]
    const CLOCK: libc::clockid_t = libc::CLOCK_MONOTONIC;

    pub fn now_ns() -> u64 {
        let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: `ts` is a valid out-pointer; the clock id is supported here.
        unsafe { libc::clock_gettime(CLOCK, &mut ts) };
        ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
    }
}

#[cfg(windows)]
mod imp {
    use windows_sys::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};

    pub fn now_ns() -> u64 {
        let (mut freq, mut ctr) = (0i64, 0i64);
        // SAFETY: valid out-pointers; both calls cannot fail on XP and later.
        unsafe {
            QueryPerformanceFrequency(&mut freq);
            QueryPerformanceCounter(&mut ctr);
        }
        // MSVC's steady_clock::now(): whole seconds and the remainder scaled
        // separately, so the multiplication cannot overflow.
        let (freq, ctr) = (freq as u64, ctr as u64);
        (ctr / freq) * 1_000_000_000 + (ctr % freq) * 1_000_000_000 / freq
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn is_monotonic_and_in_nanoseconds() {
        let a = super::steady_clock_ns();
        std::thread::sleep(std::time::Duration::from_millis(20));
        let b = super::steady_clock_ns();
        assert!(b > a);
        assert!((15_000_000..2_000_000_000).contains(&(b - a)), "elapsed {} ns", b - a);
    }
}
