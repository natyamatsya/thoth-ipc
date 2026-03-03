// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

use std::io;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::{ShmHandle, ShmOpenMode};

const SYNC_ABI_MAGIC: u32 = 0x4C49_5341; // "LISA" (LibIPC Sync ABI)
const SYNC_ABI_INIT_IN_PROGRESS: u32 = u32::MAX;
const SYNC_ABI_VERSION_MAJOR: u32 = 1;
const SYNC_ABI_VERSION_MINOR: u32 = 0;

#[cfg(target_os = "macos")]
const SYNC_BACKEND_ID: u32 = 2; // apple_ulock
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
            PrimitiveKind::Mutex => "__libipc_sync_abi_mutex",
            PrimitiveKind::Condition => "__libipc_sync_abi_condition",
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
    loop {
        let magic = stamp.magic.load(Ordering::Acquire);

        if magic == SYNC_ABI_MAGIC {
            return validate(stamp, expected, primitive);
        }

        if magic == SYNC_ABI_INIT_IN_PROGRESS {
            std::thread::yield_now();
            continue;
        }

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
            stamp.backend_id.store(expected.backend_id, Ordering::Relaxed);
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
            "sync ABI mismatch for {}: expected major.minor={}.{}, backend={}, kind={}, payload={} but found major.minor={}.{}, backend={}, kind={}, payload={}",
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
        ),
    ))
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
