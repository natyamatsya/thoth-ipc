// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Real-time thread priority shim.
// Port of cpp-ipc/include/libipc/proto/rt_prio.h.

/// Set real-time thread priority for the calling thread.
///
/// - `period_ns`: nominal period between callbacks (e.g. 5_333_333 for 256 frames @ 48 kHz).
/// - `computation_ns`: max computation time per period (default: `period_ns / 2`).
/// - `constraint_ns`: hard deadline (default: `period_ns`).
///
/// Returns `true` on success.
pub fn set_realtime_priority(
    period_ns: u64,
    computation_ns: Option<u64>,
    constraint_ns: Option<u64>,
) -> bool {
    let computation_ns = computation_ns.unwrap_or(period_ns / 2);
    let constraint_ns = constraint_ns.unwrap_or(period_ns);

    #[cfg(target_os = "macos")]
    {
        set_realtime_macos(period_ns, computation_ns, constraint_ns)
    }
    #[cfg(target_os = "linux")]
    {
        set_realtime_linux(period_ns, computation_ns, constraint_ns)
    }
    #[cfg(windows)]
    {
        set_realtime_windows(period_ns, computation_ns, constraint_ns)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
    {
        let _ = (period_ns, computation_ns, constraint_ns);
        false
    }
}

/// Compute the audio period in nanoseconds from sample rate and buffer size.
pub fn audio_period_ns(sample_rate: u32, frames_per_buffer: u32) -> u64 {
    (frames_per_buffer as u64) * 1_000_000_000 / (sample_rate as u64)
}

// ---------------------------------------------------------------------------
// macOS — Mach thread time constraint policy
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
fn set_realtime_macos(period_ns: u64, computation_ns: u64, constraint_ns: u64) -> bool {
    // mach_timebase_info to convert ns → Mach absolute time units
    #[repr(C)]
    struct MachTimebaseInfo {
        numer: u32,
        denom: u32,
    }

    extern "C" {
        fn mach_timebase_info(info: *mut MachTimebaseInfo) -> i32;
        fn pthread_mach_thread_np(thread: libc::pthread_t) -> u32; // mach_port_t
        fn thread_policy_set(thread: u32, flavor: u32, policy_info: *const u32, count: u32) -> i32;
    }

    const THREAD_TIME_CONSTRAINT_POLICY: u32 = 2;
    const THREAD_TIME_CONSTRAINT_POLICY_COUNT: u32 = 4;

    #[repr(C)]
    struct ThreadTimeConstraintPolicy {
        period: u32,
        computation: u32,
        constraint: u32,
        preemptible: i32, // boolean_t
    }

    let mut tb = MachTimebaseInfo { numer: 0, denom: 0 };
    unsafe {
        mach_timebase_info(&mut tb);
    }
    if tb.numer == 0 || tb.denom == 0 {
        return false;
    }

    let to_abs = |ns: u64| -> u32 { ((ns * tb.denom as u64) / tb.numer as u64) as u32 };

    let policy = ThreadTimeConstraintPolicy {
        period: to_abs(period_ns),
        computation: to_abs(computation_ns),
        constraint: to_abs(constraint_ns),
        preemptible: 1,
    };

    let kr = unsafe {
        let thread = libc::pthread_self();
        let mach_thread = pthread_mach_thread_np(thread);
        thread_policy_set(
            mach_thread,
            THREAD_TIME_CONSTRAINT_POLICY,
            &policy as *const _ as *const u32,
            THREAD_TIME_CONSTRAINT_POLICY_COUNT,
        )
    };
    kr == 0 // KERN_SUCCESS
}

// ---------------------------------------------------------------------------
// Linux — SCHED_FIFO (requires CAP_SYS_NICE or root)
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
fn set_realtime_linux(period_ns: u64, _computation_ns: u64, _constraint_ns: u64) -> bool {
    let _ = period_ns;
    // SCHED_FIFO with priority 80 is a common RT audio choice.
    let param = libc::sched_param { sched_priority: 80 };
    let ret =
        unsafe { libc::pthread_setschedparam(libc::pthread_self(), libc::SCHED_FIFO, &param) };
    ret == 0
}

// ---------------------------------------------------------------------------
// Windows — MMCSS "Pro Audio" via Avrt.dll, fallback to TIME_CRITICAL
// ---------------------------------------------------------------------------

#[cfg(windows)]
fn set_realtime_windows(_period_ns: u64, _computation_ns: u64, _constraint_ns: u64) -> bool {
    use windows_sys::Win32::System::Threading::{
        GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_TIME_CRITICAL,
    };
    unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL) != 0 }
}
