// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Integration tests for libipc Rust crate.
// These test the Rust-to-Rust round-trip. For true C++ interop tests,
// a companion C++ test binary should be used.

use libipc::{IpcMutex, ScopedAccess, ShmHandle, ShmOpenMode};

#[test]
fn shm_create_write_read() {
    let name = "test_rs_shm_rw";
    // Clean up any leftover from a previous run
    ShmHandle::unlink_by_name(name);

    let shm = ShmHandle::acquire(name, 4096, ShmOpenMode::CreateOrOpen)
        .expect("failed to acquire shm");

    assert!(shm.mapped_size() >= 4096);
    assert!(shm.ref_count() >= 1);

    // Write some data
    let data = b"hello from rust";
    unsafe {
        std::ptr::copy_nonoverlapping(data.as_ptr(), shm.as_mut_ptr(), data.len());
    }

    // Read it back
    let read_back =
        unsafe { std::slice::from_raw_parts(shm.as_ptr(), data.len()) };
    assert_eq!(read_back, data);

    drop(shm);
}

#[test]
fn shm_ref_counting() {
    let name = "test_rs_shm_ref";
    ShmHandle::unlink_by_name(name);

    let shm1 = ShmHandle::acquire(name, 1024, ShmOpenMode::CreateOrOpen)
        .expect("acquire 1");
    assert_eq!(shm1.ref_count(), 1);

    let shm2 = ShmHandle::acquire(name, 1024, ShmOpenMode::CreateOrOpen)
        .expect("acquire 2");
    assert_eq!(shm2.ref_count(), 2);
    assert_eq!(shm1.ref_count(), 2);

    drop(shm2);
    assert_eq!(shm1.ref_count(), 1);

    drop(shm1);
}

#[test]
fn mutex_lock_unlock() {
    let name = "test_rs_mutex";
    IpcMutex::clear_storage(name);

    let mtx = IpcMutex::open(name).expect("open mutex");
    mtx.lock().expect("lock");
    mtx.unlock().expect("unlock");
}

#[test]
fn scoped_access_write_read() {
    let shm_name = "test_rs_sa_shm";
    let mtx_name = "test_rs_sa_mtx";
    ShmHandle::unlink_by_name(shm_name);
    IpcMutex::clear_storage(mtx_name);

    let shm = ShmHandle::acquire(shm_name, 4096, ShmOpenMode::CreateOrOpen)
        .expect("acquire shm");
    let mtx = IpcMutex::open(mtx_name).expect("open mutex");

    {
        let access = ScopedAccess::new(&shm, &mtx).expect("scoped access");
        let payload = b"scoped write test";
        access.write(payload).expect("write");
    }
    // Mutex is now unlocked (dropped)

    {
        let access = ScopedAccess::new(&shm, &mtx).expect("scoped access 2");
        let (data, len) = access.read();
        assert!(len >= 17);
        assert_eq!(&data[..17], b"scoped write test");
    }
}

#[test]
fn shm_name_fnv1a_matches_cpp() {
    // Known test vector: FNV-1a of "" = 0xcbf29ce484222325
    assert_eq!(libipc::shm_name::fnv1a_64(b""), 0xcbf29ce484222325);

    // FNV-1a of "a" = 0xaf63dc4c8601ec8c
    assert_eq!(libipc::shm_name::fnv1a_64(b"a"), 0xaf63dc4c8601ec8c);

    // Verify make_shm_name prepends '/'
    let name = libipc::shm_name::make_shm_name("foo");
    assert_eq!(&name, "/foo");

    // Already has '/'
    let name2 = libipc::shm_name::make_shm_name("/bar");
    assert_eq!(&name2, "/bar");
}
