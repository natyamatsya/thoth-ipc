// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Dead-connection reaper owner table (RFC:
// context/dead-connection-reaper-rfc.md), Rust side. **Byte-exact with
// cpp/thoth-ipc/src/thoth_ipc/liveness.h** (xlang-channel-abi.md §9): a per-cc_-bit
// table of `{ pid, start_token }` in a dedicated LV_CONN__ segment. The port
// populates it on connect/disconnect so a C++ reaper (force_push / reap-on-
// connect) can reclaim a dead Rust receiver's slot — and a Rust receiver can reap
// dead peers on connect.
//
// The start-token formula MUST match C++ exactly: otherwise a C++ reaper checking
// a *live* Rust receiver would compute a different token than Rust stored and
// falsely reap it. macOS packs the BSD start time as tvsec*1e6+tvusec; Linux uses
// /proc/<pid>/stat field 22.

use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};

/// Max broadcast connection slots (C++ `notify_max_slots` / 32-bit cc_ mask).
pub const MAX_SLOTS: usize = 32;

/// One owner record per cc_ bit. Byte-exact: pid @0 (i32), start_tok @8 (u64).
#[repr(C)]
pub struct SlotOwner {
    pub pid: AtomicI32,       // @0  0 == free
    pub start_tok: AtomicU64, // @8  process start token (PID-reuse guard)
}

const _: () = {
    assert!(std::mem::size_of::<SlotOwner>() == crate::abi_generated::liveness_slot_size);
    assert!(std::mem::align_of::<SlotOwner>() == 8);
    assert!(std::mem::offset_of!(SlotOwner, pid) == crate::abi_generated::liveness_slot_pid_off);
    assert!(std::mem::offset_of!(SlotOwner, start_tok) == crate::abi_generated::liveness_slot_start_tok_off);
};

/// The LV_CONN__ segment: one owner per broadcast connection bit.
#[repr(C)]
pub struct ConnLiveness {
    pub slots: [SlotOwner; MAX_SLOTS],
}

const _: () = assert!(std::mem::size_of::<ConnLiveness>() == 512);

/// Byte size of the LV_CONN__ shm segment.
pub const LIVENESS_SHM_SIZE: usize = 512;

/// Bit position (0..31) of a single-bit connection id.
fn slot_index(bit: u32) -> usize {
    bit.trailing_zeros() as usize
}

#[cfg(unix)]
fn self_pid() -> i32 {
    unsafe { libc::getpid() }
}
#[cfg(windows)]
fn self_pid() -> i32 {
    unsafe { windows_sys::Win32::System::Threading::GetCurrentProcessId() as i32 }
}

// ---------------------------------------------------------------------------
// Process start token (byte-exact with C++ start_token)
// ---------------------------------------------------------------------------

#[cfg(target_vendor = "apple")]
fn start_token(pid: i32) -> u64 {
    apple::start_token(pid)
}
#[cfg(all(unix, not(target_vendor = "apple")))]
fn start_token(pid: i32) -> u64 {
    linux::start_token(pid)
}
#[cfg(windows)]
fn start_token(pid: i32) -> u64 {
    windows_impl::creation_token(pid)
}

/// Is the recorded process (pid + token) still alive? Conservative: any
/// "can't determine" answer errs toward ALIVE so a live peer is never false-reaped.
#[cfg(unix)]
fn is_process_alive(pid: i32, tok: u64) -> bool {
    if pid <= 0 {
        return false;
    }
    let rc = unsafe { libc::kill(pid, 0) };
    let exists = rc == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH);
    if !exists {
        return false; // definitely gone
    }
    if tok == 0 {
        return true; // no recorded token → token-less fallback
    }
    let cur = start_token(pid);
    if cur == 0 {
        return true; // couldn't read current token → don't risk a false reap
    }
    cur == tok // mismatch ⇒ PID was reused ⇒ our owner is gone
}
#[cfg(windows)]
fn is_process_alive(pid: i32, tok: u64) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_INVALID_PARAMETER};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    const STILL_ACTIVE: u32 = 259;
    if pid <= 0 {
        return false;
    }
    let h = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32) };
    if h.is_null() {
        // ERROR_INVALID_PARAMETER ⇒ no such PID ⇒ gone. Any other failure
        // (e.g. access denied) ⇒ the process exists but we can't inspect it ⇒
        // conservatively ALIVE (never false-reap), mirroring POSIX EPERM.
        return unsafe { GetLastError() } != ERROR_INVALID_PARAMETER;
    }
    let mut code: u32 = 0;
    let mut alive = true;
    if unsafe { GetExitCodeProcess(h, &mut code) } != 0 {
        alive = code == STILL_ACTIVE; // a real exit code 259 stays "alive" — conservative
    }
    let cur = if alive {
        windows_impl::creation_token_of(h)
    } else {
        0
    };
    unsafe { CloseHandle(h) };
    if !alive {
        return false; // definitely gone
    }
    if tok == 0 {
        return true; // no recorded token → token-less fallback
    }
    if cur == 0 {
        return true; // couldn't read current token → don't risk a false reap
    }
    cur == tok // mismatch ⇒ PID was reused ⇒ our owner is gone
}

#[cfg(windows)]
mod windows_impl {
    use windows_sys::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
    use windows_sys::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    /// Read the process creation FILETIME (100-ns ticks since 1601) from an open
    /// handle and pack it high:low — the Windows row of the xlang §9 token
    /// formula. Byte-identical to C++ `start_token`. 0 ⇒ couldn't determine.
    pub(super) fn creation_token_of(h: HANDLE) -> u64 {
        let mut creation = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let mut exit_t = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let mut kernel_t = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let mut user_t = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        let ok = unsafe {
            GetProcessTimes(h, &mut creation, &mut exit_t, &mut kernel_t, &mut user_t)
        };
        if ok != 0 {
            ((creation.dwHighDateTime as u64) << 32) | (creation.dwLowDateTime as u64)
        } else {
            0
        }
    }

    /// Open `pid`, read its creation token, close. 0 ⇒ couldn't determine.
    pub(super) fn creation_token(pid: i32) -> u64 {
        if pid <= 0 {
            return 0;
        }
        let h = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32) };
        if h.is_null() {
            return 0;
        }
        let t = creation_token_of(h);
        unsafe { CloseHandle(h) };
        t
    }
}

// ---------------------------------------------------------------------------
// Owner table operations
// ---------------------------------------------------------------------------

/// Record ownership of a freshly connected slot (after the cc_ bit is claimed).
pub fn set_owner(lv: *mut ConnLiveness, bit: u32) {
    if lv.is_null() || bit == 0 {
        return;
    }
    let s = unsafe { &(*lv).slots[slot_index(bit)] };
    // Token first, then pid with release: a reader that sees our pid sees the token.
    s.start_tok.store(start_token(self_pid()), Ordering::Relaxed);
    s.pid.store(self_pid(), Ordering::Release);
}

/// Release ownership of a slot on clean disconnect.
pub fn clear_owner(lv: *mut ConnLiveness, bit: u32) {
    if lv.is_null() || bit == 0 {
        return;
    }
    let s = unsafe { &(*lv).slots[slot_index(bit)] };
    s.pid.store(0, Ordering::Release);
    s.start_tok.store(0, Ordering::Relaxed);
}

/// Reap the dead receivers among `live`, clearing each via `disconnect_fn(bit)`.
/// Lock-free (CAS-on-owner). Returns the reaped mask.
pub fn reap_dead_receivers<F: FnMut(u32)>(lv: *mut ConnLiveness, live: u32, mut disconnect_fn: F) -> u32 {
    if lv.is_null() {
        return 0;
    }
    let mut reaped = 0u32;
    let mut m = live;
    while m != 0 {
        let bit = m & m.wrapping_neg(); // lowest set bit
        m &= m - 1;
        let s = unsafe { &(*lv).slots[slot_index(bit)] };
        let p = s.pid.load(Ordering::Acquire);
        if p == 0 {
            continue; // unknown owner — never false-reap
        }
        let tok = s.start_tok.load(Ordering::Relaxed);
        if is_process_alive(p, tok) {
            continue;
        }
        // Only reap if the owner is still the dead PID we saw.
        if s.pid.compare_exchange(p, 0, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
            s.start_tok.store(0, Ordering::Relaxed);
            disconnect_fn(bit);
            reaped |= bit;
        }
    }
    reaped
}

// ---------------------------------------------------------------------------
// Platform start-token backends
// ---------------------------------------------------------------------------

#[cfg(target_vendor = "apple")]
mod apple {
    // struct proc_bsdinfo from <sys/proc_info.h> (MAXCOMLEN = 16). We only read
    // the two start-time fields, but the layout must match so proc_pidinfo fills
    // the right offsets. sizeof == 136; pbi_start_tvsec @120, pbi_start_tvusec @128.
    #[repr(C)]
    struct ProcBsdInfo {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: u32,
        pbi_gid: u32,
        pbi_ruid: u32,
        pbi_rgid: u32,
        pbi_svuid: u32,
        pbi_svgid: u32,
        rfu_1: u32,
        pbi_comm: [u8; 16],
        pbi_name: [u8; 32],
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    }

    const _: () = {
        assert!(std::mem::size_of::<ProcBsdInfo>() == 136);
        assert!(std::mem::offset_of!(ProcBsdInfo, pbi_start_tvsec) == 120);
        assert!(std::mem::offset_of!(ProcBsdInfo, pbi_start_tvusec) == 128);
    };

    const PROC_PIDTBSDINFO: libc::c_int = 3;

    extern "C" {
        fn proc_pidinfo(
            pid: libc::c_int,
            flavor: libc::c_int,
            arg: u64,
            buffer: *mut libc::c_void,
            buffersize: libc::c_int,
        ) -> libc::c_int;
    }

    pub fn start_token(pid: i32) -> u64 {
        if pid <= 0 {
            return 0;
        }
        let mut info: ProcBsdInfo = unsafe { std::mem::zeroed() };
        let sz = std::mem::size_of::<ProcBsdInfo>() as libc::c_int;
        let n = unsafe {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &mut info as *mut _ as *mut libc::c_void, sz)
        };
        if n != sz {
            return 0;
        }
        info.pbi_start_tvsec
            .wrapping_mul(1_000_000)
            .wrapping_add(info.pbi_start_tvusec)
    }
}

#[cfg(all(unix, not(target_vendor = "apple")))]
mod linux {
    pub fn start_token(pid: i32) -> u64 {
        if pid <= 0 {
            return 0;
        }
        let data = match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(d) => d,
            Err(_) => return 0,
        };
        // Field 2 (comm) is parenthesised and may contain spaces — skip past the
        // last ')'. After it: field 3 (state) onward; starttime is field 22.
        let rest = match data.rfind(')') {
            Some(i) => &data[i + 1..],
            None => return 0,
        };
        // fields[0] is field 3, so field 22 is fields[19].
        rest.split_whitespace()
            .nth(19)
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn self_token_and_reuse_detection() {
        let me = self_pid();
        let tok = start_token(me);
        assert!(is_process_alive(me, tok));
        if tok != 0 {
            // A live PID with a WRONG token looks like a recycled PID → gone.
            assert!(!is_process_alive(me, tok ^ 0x5eed));
        }
        assert!(!is_process_alive(-1, tok));
    }
}
