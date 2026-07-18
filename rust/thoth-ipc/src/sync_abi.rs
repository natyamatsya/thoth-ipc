// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

use std::io;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use crate::abi_generated as abi;
use crate::{ShmHandle, ShmOpenMode};

const SYNC_ABI_MAGIC: u32 = abi::syncabi_magic; // "LISA" (LibIPC Sync ABI)
const SYNC_ABI_INIT_IN_PROGRESS: u32 = u32::MAX;
const SYNC_ABI_VERSION_MAJOR: u32 = 1;
const SYNC_ABI_VERSION_MINOR: u32 = 0;
/// How long a concurrent opener will wait for another thread/process that has
/// claimed the `INIT_IN_PROGRESS` slot to publish the finished stamp before it
/// gives up and reports a stalled (presumably dead) initializer.
///
/// The initializer's critical section is a handful of relaxed atomic stores —
/// nanoseconds in the common case — but it can be preempted, and multiple
/// waiters used to burn a fixed *spin count* fast enough to falsely time out a
/// merely-descheduled initializer (and, by busy-spinning, starve it of the CPU
/// it needed to finish). A generous wall-clock deadline plus backoff that
/// actually sleeps makes the wait robust: a live initializer always wins, and
/// only a genuinely dead one (crashed mid-init) trips the timeout.
const SYNC_ABI_INIT_TIMEOUT: Duration = Duration::from_secs(2);

#[cfg(target_os = "macos")]
const SYNC_BACKEND_ID: u32 = abi::syncabi_backend_ulock; // apple_ulock
#[cfg(all(unix, not(target_os = "macos")))]
const SYNC_BACKEND_ID: u32 = 1; // posix_pthread
#[cfg(windows)]
const SYNC_BACKEND_ID: u32 = 4; // win32

pub(crate) struct SyncAbiGuard {
    _shm: ShmHandle,
}

impl SyncAbiGuard {
    fn new(shm: ShmHandle) -> Self {
        Self { _shm: shm }
    }
}

#[derive(Clone, Copy)]
enum PrimitiveKind {
    Mutex,
    Condition,
}

impl PrimitiveKind {
    fn id(self) -> u32 {
        match self {
            PrimitiveKind::Mutex => 1,
            PrimitiveKind::Condition => 2,
        }
    }

    fn sidecar_suffix(self) -> &'static str {
        match self {
            PrimitiveKind::Mutex => "__thoth_ipc_sync_abi_mutex",
            PrimitiveKind::Condition => "__thoth_ipc_sync_abi_condition",
        }
    }

    fn label(self) -> &'static str {
        match self {
            PrimitiveKind::Mutex => "mutex",
            PrimitiveKind::Condition => "condition",
        }
    }

    fn expected_payload_size(self) -> u32 {
        match self {
            PrimitiveKind::Mutex => {
                #[cfg(target_os = "macos")]
                {
                    8 // ulock mutex state (u32) + holder (u32)
                }
                #[cfg(all(unix, not(target_os = "macos")))]
                {
                    std::mem::size_of::<libc::pthread_mutex_t>() as u32
                }
                #[cfg(windows)]
                {
                    0 // kernel object, no shared payload layout contract
                }
            }
            PrimitiveKind::Condition => {
                #[cfg(target_os = "macos")]
                {
                    8 // ulock condition state: seq (u32) + waiters (i32)
                }
                #[cfg(all(unix, not(target_os = "macos")))]
                {
                    std::mem::size_of::<libc::pthread_cond_t>() as u32
                }
                #[cfg(windows)]
                {
                    0 // emulated condition, no fixed shared payload layout
                }
            }
        }
    }
}

#[repr(C)]
struct SyncAbiStamp {
    magic: AtomicU32,
    abi_version_major: AtomicU32,
    abi_version_minor: AtomicU32,
    backend_id: AtomicU32,
    primitive_kind: AtomicU32,
    payload_size: AtomicU32,
}

// Compile-time guard: the stamp must match the generated ABI layout.
const _: () = {
    assert!(std::mem::size_of::<SyncAbiStamp>() == abi::syncabi_stamp_size);
    assert!(std::mem::offset_of!(SyncAbiStamp, magic) == abi::syncabi_stamp_magic_off);
    assert!(std::mem::offset_of!(SyncAbiStamp, abi_version_major) == abi::syncabi_stamp_ver_major_off);
    assert!(std::mem::offset_of!(SyncAbiStamp, abi_version_minor) == abi::syncabi_stamp_ver_minor_off);
    assert!(std::mem::offset_of!(SyncAbiStamp, backend_id) == abi::syncabi_stamp_backend_id_off);
    assert!(std::mem::offset_of!(SyncAbiStamp, primitive_kind) == abi::syncabi_stamp_primitive_id_off);
    assert!(std::mem::offset_of!(SyncAbiStamp, payload_size) == abi::syncabi_stamp_payload_size_off);
};

#[derive(Clone, Copy)]
struct SyncAbiExpected {
    abi_version_major: u32,
    abi_version_minor: u32,
    backend_id: u32,
    primitive_kind: u32,
    payload_size: u32,
}

fn metadata_name(name: &str, primitive: PrimitiveKind) -> String {
    format!("{name}{}", primitive.sidecar_suffix())
}

fn expected_for(primitive: PrimitiveKind) -> SyncAbiExpected {
    SyncAbiExpected {
        abi_version_major: SYNC_ABI_VERSION_MAJOR,
        abi_version_minor: SYNC_ABI_VERSION_MINOR,
        backend_id: SYNC_BACKEND_ID,
        primitive_kind: primitive.id(),
        payload_size: primitive.expected_payload_size(),
    }
}

fn ensure(name: &str, primitive: PrimitiveKind) -> io::Result<SyncAbiGuard> {
    if name.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "name is empty"));
    }

    let shm = ShmHandle::acquire(
        &metadata_name(name, primitive),
        std::mem::size_of::<SyncAbiStamp>(),
        ShmOpenMode::CreateOrOpen,
    )?;

    let stamp = unsafe { &*(shm.as_mut_ptr() as *const SyncAbiStamp) };
    init_or_validate(stamp, expected_for(primitive), primitive)?;

    Ok(SyncAbiGuard::new(shm))
}

fn init_or_validate(
    stamp: &SyncAbiStamp,
    expected: SyncAbiExpected,
    primitive: PrimitiveKind,
) -> io::Result<()> {
    init_or_validate_within(stamp, expected, primitive, SYNC_ABI_INIT_TIMEOUT)
}

fn init_or_validate_within(
    stamp: &SyncAbiStamp,
    expected: SyncAbiExpected,
    primitive: PrimitiveKind,
    init_timeout: Duration,
) -> io::Result<()> {
    // Spin count *within the current INIT_IN_PROGRESS wait* — drives backoff
    // escalation only; the give-up decision is wall-clock based (`deadline`).
    let mut init_wait_spins = 0u32;
    // Lazily armed on the first INIT_IN_PROGRESS observation so an already-live
    // stamp (or one we initialize ourselves) never pays for a clock read.
    let mut deadline: Option<Instant> = None;
    loop {
        let magic = stamp.magic.load(Ordering::Acquire);

        if magic == SYNC_ABI_MAGIC {
            return validate(stamp, expected, primitive);
        }

        if magic == SYNC_ABI_INIT_IN_PROGRESS {
            let deadline = *deadline.get_or_insert_with(|| Instant::now() + init_timeout);
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!(
                        "sync ABI init stalled for {}: stuck at INIT_IN_PROGRESS",
                        primitive.label()
                    ),
                ));
            }
            // Back off with an escalating strategy: a brief CPU spin for the
            // common sub-microsecond case, then `yield_now`, then an actual
            // sleep. Sleeping (rather than spinning) hands the CPU back to the
            // initializer so it can finish, instead of starving it.
            if init_wait_spins < 64 {
                std::hint::spin_loop();
            } else if init_wait_spins < 1024 {
                std::thread::yield_now();
            } else {
                std::thread::sleep(Duration::from_micros(200));
            }
            init_wait_spins = init_wait_spins.saturating_add(1);
            continue;
        }

        init_wait_spins = 0;
        deadline = None;

        if magic == 0 {
            if stamp
                .magic
                .compare_exchange(
                    0,
                    SYNC_ABI_INIT_IN_PROGRESS,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_err()
            {
                continue;
            }

            stamp
                .abi_version_major
                .store(expected.abi_version_major, Ordering::Relaxed);
            stamp
                .abi_version_minor
                .store(expected.abi_version_minor, Ordering::Relaxed);
            stamp
                .backend_id
                .store(expected.backend_id, Ordering::Relaxed);
            stamp
                .primitive_kind
                .store(expected.primitive_kind, Ordering::Relaxed);
            stamp
                .payload_size
                .store(expected.payload_size, Ordering::Relaxed);
            stamp.magic.store(SYNC_ABI_MAGIC, Ordering::Release);
            return Ok(());
        }

        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "sync ABI stamp magic mismatch for {}: expected {SYNC_ABI_MAGIC:#x}, found {magic:#x}",
                primitive.label()
            ),
        ));
    }
}

fn validate(
    stamp: &SyncAbiStamp,
    expected: SyncAbiExpected,
    primitive: PrimitiveKind,
) -> io::Result<()> {
    let actual = SyncAbiExpected {
        abi_version_major: stamp.abi_version_major.load(Ordering::Acquire),
        abi_version_minor: stamp.abi_version_minor.load(Ordering::Acquire),
        backend_id: stamp.backend_id.load(Ordering::Acquire),
        primitive_kind: stamp.primitive_kind.load(Ordering::Acquire),
        payload_size: stamp.payload_size.load(Ordering::Acquire),
    };

    if actual.abi_version_major == expected.abi_version_major
        && actual.abi_version_minor == expected.abi_version_minor
        && actual.backend_id == expected.backend_id
        && actual.primitive_kind == expected.primitive_kind
        && actual.payload_size == expected.payload_size
    {
        return Ok(());
    }

    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "sync ABI mismatch for {}: expected major.minor={}.{}, backend={}, kind={}, payload={} but found major.minor={}.{}, backend={}, kind={}, payload={}{}",
            primitive.label(),
            expected.abi_version_major,
            expected.abi_version_minor,
            expected.backend_id,
            expected.primitive_kind,
            expected.payload_size,
            actual.abi_version_major,
            actual.abi_version_minor,
            actual.backend_id,
            actual.primitive_kind,
            actual.payload_size,
            backend_mismatch_hint(expected.backend_id, actual.backend_id),
        ),
    ))
}

#[cfg(target_os = "macos")]
fn backend_mismatch_hint(expected_backend: u32, actual_backend: u32) -> &'static str {
    if (expected_backend == 2 && actual_backend == 3)
        || (expected_backend == 3 && actual_backend == 2)
    {
        "; macOS profile mismatch: apple_ulock (2) cannot interop with apple_mach (3)"
    } else {
        ""
    }
}

#[cfg(not(target_os = "macos"))]
fn backend_mismatch_hint(_expected_backend: u32, _actual_backend: u32) -> &'static str {
    ""
}

pub(crate) fn open_mutex_guard(name: &str) -> io::Result<SyncAbiGuard> {
    ensure(name, PrimitiveKind::Mutex)
}

pub(crate) fn open_condition_guard(name: &str) -> io::Result<SyncAbiGuard> {
    ensure(name, PrimitiveKind::Condition)
}

pub(crate) fn clear_mutex_storage(name: &str) {
    ShmHandle::unlink_by_name(&metadata_name(name, PrimitiveKind::Mutex));
}

pub(crate) fn clear_condition_storage(name: &str) {
    ShmHandle::unlink_by_name(&metadata_name(name, PrimitiveKind::Condition));
}

#[cfg(test)]
mod tests {
    use std::io::ErrorKind;

    use super::*;

    fn empty_stamp() -> SyncAbiStamp {
        SyncAbiStamp {
            magic: AtomicU32::new(0),
            abi_version_major: AtomicU32::new(0),
            abi_version_minor: AtomicU32::new(0),
            backend_id: AtomicU32::new(0),
            primitive_kind: AtomicU32::new(0),
            payload_size: AtomicU32::new(0),
        }
    }

    fn write_expected_stamp(stamp: &SyncAbiStamp, expected: SyncAbiExpected) {
        stamp
            .abi_version_major
            .store(expected.abi_version_major, Ordering::Relaxed);
        stamp
            .abi_version_minor
            .store(expected.abi_version_minor, Ordering::Relaxed);
        stamp
            .backend_id
            .store(expected.backend_id, Ordering::Relaxed);
        stamp
            .primitive_kind
            .store(expected.primitive_kind, Ordering::Relaxed);
        stamp
            .payload_size
            .store(expected.payload_size, Ordering::Relaxed);
        stamp.magic.store(SYNC_ABI_MAGIC, Ordering::Release);
    }

    #[test]
    fn init_or_validate_times_out_when_init_is_stuck() {
        let stamp = empty_stamp();
        stamp
            .magic
            .store(SYNC_ABI_INIT_IN_PROGRESS, Ordering::Release);

        let err = init_or_validate_within(
            &stamp,
            expected_for(PrimitiveKind::Mutex),
            PrimitiveKind::Mutex,
            Duration::from_millis(50),
        )
        .expect_err("stuck INIT_IN_PROGRESS must not spin forever");

        assert_eq!(err.kind(), ErrorKind::TimedOut);
    }

    #[test]
    fn init_or_validate_rejects_backend_mismatch() {
        let stamp = empty_stamp();
        let expected = expected_for(PrimitiveKind::Condition);

        write_expected_stamp(&stamp, expected);
        stamp
            .backend_id
            .store(expected.backend_id.wrapping_add(1), Ordering::Release);

        let err = init_or_validate(&stamp, expected, PrimitiveKind::Condition)
            .expect_err("backend mismatch must fail validation");

        assert_eq!(err.kind(), ErrorKind::InvalidData);
    }

    #[test]
    fn init_or_validate_initializes_empty_stamp() {
        let stamp = empty_stamp();
        let expected = expected_for(PrimitiveKind::Mutex);

        init_or_validate(&stamp, expected, PrimitiveKind::Mutex)
            .expect("empty stamp must initialize successfully");

        assert_eq!(stamp.magic.load(Ordering::Acquire), SYNC_ABI_MAGIC);
        assert_eq!(
            stamp.abi_version_major.load(Ordering::Acquire),
            expected.abi_version_major
        );
        assert_eq!(
            stamp.abi_version_minor.load(Ordering::Acquire),
            expected.abi_version_minor
        );
        assert_eq!(
            stamp.backend_id.load(Ordering::Acquire),
            expected.backend_id
        );
        assert_eq!(
            stamp.primitive_kind.load(Ordering::Acquire),
            expected.primitive_kind
        );
        assert_eq!(
            stamp.payload_size.load(Ordering::Acquire),
            expected.payload_size
        );
    }
}
