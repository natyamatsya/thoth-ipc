// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-platform process spawning and lifecycle management.
// Port of cpp-ipc/include/libipc/proto/process_manager.h.

use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// ProcessHandle
// ---------------------------------------------------------------------------

/// Handle to a spawned child process.
#[derive(Debug, Clone)]
pub struct ProcessHandle {
    pub pid: u32,
    /// Logical name (for registry).
    pub name: String,
    /// Path to the binary.
    pub executable: String,
    #[cfg(windows)]
    hprocess: isize, // HANDLE
}

impl ProcessHandle {
    pub fn invalid() -> Self {
        Self {
            pid: 0,
            name: String::new(),
            executable: String::new(),
            #[cfg(windows)]
            hprocess: 0,
        }
    }

    pub fn valid(&self) -> bool {
        self.pid > 0
    }

    pub fn is_alive(&self) -> bool {
        if !self.valid() {
            return false;
        }
        #[cfg(unix)]
        {
            unsafe {
                libc::kill(self.pid as libc::pid_t, 0) == 0 || *libc::__error() != libc::ESRCH
            }
        }
        #[cfg(windows)]
        {
            use windows_sys::Win32::Foundation::STILL_ACTIVE;
            use windows_sys::Win32::System::Threading::GetExitCodeProcess;
            unsafe {
                let mut code: u32 = 0;
                GetExitCodeProcess(self.hprocess, &mut code) != 0 && code == STILL_ACTIVE
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            true
        }
    }
}

#[cfg(windows)]
impl Drop for ProcessHandle {
    fn drop(&mut self) {
        if self.hprocess != 0 {
            unsafe {
                windows_sys::Win32::Foundation::CloseHandle(self.hprocess);
            }
            self.hprocess = 0;
        }
    }
}

// ---------------------------------------------------------------------------
// WaitResult
// ---------------------------------------------------------------------------

/// Result of a [`wait_for_exit`] call.
#[derive(Debug, Default, Clone, Copy)]
pub struct WaitResult {
    pub exited: bool,
    pub exit_code: i32,
    pub signaled: bool,
    pub signal: i32,
}

// ---------------------------------------------------------------------------
// spawn
// ---------------------------------------------------------------------------

/// Spawn a child process.
///
/// `name` is a logical label stored in the handle (used by the service registry).
/// `executable` is the path to the binary.
/// `args` are additional command-line arguments.
pub fn spawn(name: &str, executable: &str, args: &[&str]) -> ProcessHandle {
    let mut h = ProcessHandle::invalid();
    h.name = name.to_owned();
    h.executable = executable.to_owned();

    #[cfg(unix)]
    {
        use std::ffi::CString;

        extern "C" {
            static mut environ: *mut *mut libc::c_char;
        }

        let exe = match CString::new(executable) {
            Ok(s) => s,
            Err(_) => return h,
        };
        let mut argv: Vec<CString> = Vec::with_capacity(args.len() + 2);
        argv.push(exe.clone());
        for a in args {
            match CString::new(*a) {
                Ok(s) => argv.push(s),
                Err(_) => return h,
            }
        }
        argv.push(CString::new("").unwrap()); // null terminator placeholder

        let mut argv_ptrs: Vec<*mut libc::c_char> = argv
            .iter()
            .map(|s| s.as_ptr() as *mut libc::c_char)
            .collect();
        // Replace last placeholder with null
        *argv_ptrs.last_mut().unwrap() = std::ptr::null_mut();

        let mut pid: libc::pid_t = -1;
        let err = unsafe {
            libc::posix_spawn(
                &mut pid,
                exe.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                argv_ptrs.as_mut_ptr(),
                environ,
            )
        };
        if err != 0 {
            return h;
        }
        h.pid = pid as u32;
    }

    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            CreateProcessA, PROCESS_INFORMATION, STARTUPINFOA,
        };

        let mut cmdline = executable.to_owned();
        for a in args {
            cmdline.push(' ');
            cmdline.push_str(a);
        }
        cmdline.push('\0');

        let mut si: STARTUPINFOA = unsafe { std::mem::zeroed() };
        si.cb = std::mem::size_of::<STARTUPINFOA>() as u32;
        let mut pi: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

        let ok = unsafe {
            CreateProcessA(
                std::ptr::null(),
                cmdline.as_mut_ptr() as *mut u8,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
                0,
                std::ptr::null_mut(),
                std::ptr::null(),
                &si,
                &mut pi,
            )
        };
        if ok == 0 {
            return h;
        }
        h.pid = pi.dwProcessId;
        h.hprocess = pi.hProcess as isize;
        unsafe {
            CloseHandle(pi.hThread);
        }
    }

    h
}

/// Spawn with no extra arguments.
pub fn spawn_simple(name: &str, executable: &str) -> ProcessHandle {
    spawn(name, executable, &[])
}

// ---------------------------------------------------------------------------
// request_shutdown / force_kill
// ---------------------------------------------------------------------------

/// Send SIGTERM (POSIX) or TerminateProcess (Windows) to request graceful shutdown.
pub fn request_shutdown(h: &ProcessHandle) -> bool {
    if !h.valid() {
        return false;
    }
    #[cfg(unix)]
    {
        unsafe { libc::kill(h.pid as libc::pid_t, libc::SIGTERM) == 0 }
    }
    #[cfg(windows)]
    {
        unsafe { windows_sys::Win32::System::Threading::TerminateProcess(h.hprocess, 1) != 0 }
    }
    #[cfg(not(any(unix, windows)))]
    {
        false
    }
}

/// Send SIGKILL (POSIX) or TerminateProcess(9) (Windows) to forcefully terminate.
pub fn force_kill(h: &ProcessHandle) -> bool {
    if !h.valid() {
        return false;
    }
    #[cfg(unix)]
    {
        unsafe { libc::kill(h.pid as libc::pid_t, libc::SIGKILL) == 0 }
    }
    #[cfg(windows)]
    {
        unsafe { windows_sys::Win32::System::Threading::TerminateProcess(h.hprocess, 9) != 0 }
    }
    #[cfg(not(any(unix, windows)))]
    {
        false
    }
}

// ---------------------------------------------------------------------------
// wait_for_exit
// ---------------------------------------------------------------------------

/// Wait for a process to exit, with a timeout.
/// Returns immediately if the process has already exited.
pub fn wait_for_exit(h: &ProcessHandle, timeout: Duration) -> WaitResult {
    let mut r = WaitResult::default();
    if !h.valid() {
        return r;
    }

    #[cfg(unix)]
    {
        let deadline = Instant::now() + timeout;
        loop {
            let mut status: libc::c_int = 0;
            let ret = unsafe { libc::waitpid(h.pid as libc::pid_t, &mut status, libc::WNOHANG) };
            if ret == h.pid as libc::pid_t {
                if libc::WIFEXITED(status) {
                    r.exited = true;
                    r.exit_code = libc::WEXITSTATUS(status);
                }
                if libc::WIFSIGNALED(status) {
                    r.signaled = true;
                    r.signal = libc::WTERMSIG(status);
                }
                return r;
            }
            if ret == -1 {
                return r;
            }
            if Instant::now() >= deadline {
                return r;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Threading::{
            GetExitCodeProcess, WaitForSingleObject, WAIT_OBJECT_0,
        };
        let ms = timeout.as_millis().min(u32::MAX as u128) as u32;
        let ret = unsafe { WaitForSingleObject(h.hprocess, ms) };
        if ret == WAIT_OBJECT_0 {
            let mut code: u32 = 0;
            unsafe {
                GetExitCodeProcess(h.hprocess, &mut code);
            }
            r.exited = true;
            r.exit_code = code as i32;
        }
        r
    }

    #[cfg(not(any(unix, windows)))]
    {
        r
    }
}

// ---------------------------------------------------------------------------
// shutdown (graceful: SIGTERM → wait → SIGKILL)
// ---------------------------------------------------------------------------

/// Gracefully shut down a process: SIGTERM → wait `grace` → SIGKILL if still alive.
pub fn shutdown(h: &ProcessHandle, grace: Duration) -> WaitResult {
    if !h.valid() {
        return WaitResult::default();
    }
    request_shutdown(h);
    let r = wait_for_exit(h, grace);
    if !r.exited && !r.signaled && h.is_alive() {
        force_kill(h);
        return wait_for_exit(h, Duration::from_secs(1));
    }
    r
}
