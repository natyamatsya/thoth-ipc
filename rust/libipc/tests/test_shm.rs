// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_shm.cpp
// Comprehensive unit tests for shared memory functionality.

use std::sync::atomic::{AtomicUsize, Ordering};

use libipc::{ShmHandle, ShmOpenMode};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_shm_{n}")
}

// ========== Low-level API Tests ==========

// Port of ShmTest.AcquireCreate
#[test]
fn acquire_create() {
    let name = unique_name("acquire_create");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 1024, ShmOpenMode::Create)
        .expect("acquire create");
    assert!(shm.mapped_size() >= 1024);
    assert_ne!(shm.as_ptr() as usize, 0);
}

// Port of ShmTest.AcquireOpenNonExistent
#[test]
fn acquire_open_nonexistent() {
    let name = unique_name("acquire_open_fail");
    ShmHandle::unlink_by_name(&name);

    let result = ShmHandle::acquire(&name, 1024, ShmOpenMode::Open);
    // Opening non-existent shared memory should fail
    assert!(result.is_err());
}

// Port of ShmTest.AcquireCreateOrOpen
#[test]
fn acquire_create_or_open() {
    let name = unique_name("acquire_both");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 2048, ShmOpenMode::CreateOrOpen)
        .expect("acquire create_or_open");
    assert!(shm.mapped_size() >= 2048);
    assert_ne!(shm.as_ptr() as usize, 0);
}

// Port of ShmTest.GetMemory — write and read test data
#[test]
fn get_memory_write_read() {
    let name = unique_name("get_mem");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 512, ShmOpenMode::Create)
        .expect("acquire");
    assert_ne!(shm.as_ptr() as usize, 0);
    assert!(shm.mapped_size() >= 512);

    let test_data = b"Shared memory test data";
    unsafe {
        std::ptr::copy_nonoverlapping(test_data.as_ptr(), shm.as_mut_ptr(), test_data.len());
    }
    let read_back = unsafe { std::slice::from_raw_parts(shm.as_ptr(), test_data.len()) };
    assert_eq!(read_back, test_data);
}

// Port of ShmTest.ReleaseMemory
#[test]
fn release_memory_ref_count() {
    let name = unique_name("release");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 128, ShmOpenMode::Create)
        .expect("acquire");
    assert_eq!(shm.ref_count(), 1);

    drop(shm);
    // After drop, the segment should be unlinked (ref_count was 1).
}

// Port of ShmTest.ReferenceCount
#[test]
fn reference_count() {
    let name = unique_name("ref_count");
    ShmHandle::unlink_by_name(&name);

    let shm1 = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen)
        .expect("acquire 1");
    assert_eq!(shm1.ref_count(), 1);

    let shm2 = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen)
        .expect("acquire 2");
    assert_eq!(shm1.ref_count(), 2);
    assert_eq!(shm2.ref_count(), 2);

    drop(shm2);
    assert_eq!(shm1.ref_count(), 1);

    drop(shm1);
}

// Port of ShmTest.HandleConstructorWithParams
#[test]
fn handle_with_params() {
    let name = unique_name("handle_ctor");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 1024, ShmOpenMode::CreateOrOpen)
        .expect("acquire");
    assert!(shm.mapped_size() >= 1024);
    assert_ne!(shm.as_ptr() as usize, 0);
}

// Port of ShmTest.HandleValid (default vs valid)
#[test]
fn handle_valid() {
    // Acquiring with valid params should succeed
    let name = unique_name("handle_valid");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 128, ShmOpenMode::CreateOrOpen)
        .expect("acquire");
    assert_ne!(shm.as_ptr() as usize, 0);
    assert!(shm.mapped_size() > 0);
}

// Port of ShmTest.HandleSize
#[test]
fn handle_size() {
    let name = unique_name("handle_size");
    ShmHandle::unlink_by_name(&name);

    let requested_size = 2048;
    let shm = ShmHandle::acquire(&name, requested_size, ShmOpenMode::CreateOrOpen)
        .expect("acquire");
    assert!(shm.mapped_size() >= requested_size);
}

// Port of ShmTest.HandleRef
#[test]
fn handle_ref() {
    let name = unique_name("handle_ref");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 256, ShmOpenMode::CreateOrOpen)
        .expect("acquire");
    assert!(shm.ref_count() > 0);
}

// Port of ShmTest.HandleGet (write and read)
#[test]
fn handle_get_write_read() {
    let name = unique_name("handle_get");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen)
        .expect("acquire");

    let test_str = b"Handle get test";
    unsafe {
        std::ptr::copy_nonoverlapping(test_str.as_ptr(), shm.as_mut_ptr(), test_str.len());
    }
    let read_back = unsafe { std::slice::from_raw_parts(shm.as_ptr(), test_str.len()) };
    assert_eq!(read_back, test_str);
}

// Port of ShmTest.WriteReadData (struct through shared memory)
#[test]
fn write_read_struct() {
    let name = unique_name("write_read");
    ShmHandle::unlink_by_name(&name);

    #[repr(C)]
    #[derive(Debug, Clone, Copy, PartialEq)]
    struct TestData {
        value: i32,
        text: [u8; 64],
    }

    let shm1 = ShmHandle::acquire(&name, 1024, ShmOpenMode::CreateOrOpen)
        .expect("acquire 1");

    let data = TestData {
        value: 42,
        text: {
            let mut buf = [0u8; 64];
            let msg = b"Shared memory data";
            buf[..msg.len()].copy_from_slice(msg);
            buf
        },
    };

    unsafe {
        let ptr = shm1.as_mut_ptr() as *mut TestData;
        std::ptr::write(ptr, data);
    }

    // Open in a second handle (simulating different process)
    let shm2 = ShmHandle::acquire(&name, 1024, ShmOpenMode::CreateOrOpen)
        .expect("acquire 2");
    let read_data = unsafe { &*(shm2.as_ptr() as *const TestData) };
    assert_eq!(read_data.value, 42);
    assert_eq!(&read_data.text[..18], b"Shared memory data");
}

// Port of ShmTest.HandleModes
#[test]
fn handle_modes() {
    let name = unique_name("handle_modes");
    ShmHandle::unlink_by_name(&name);

    // Create only
    let h1 = ShmHandle::acquire(&name, 256, ShmOpenMode::Create)
        .expect("create");
    assert!(h1.mapped_size() >= 256);

    // Open existing
    let h2 = ShmHandle::acquire(&name, 256, ShmOpenMode::Open)
        .expect("open");
    assert!(h2.mapped_size() >= 256);

    // Create-or-open (existing)
    let h3 = ShmHandle::acquire(&name, 256, ShmOpenMode::CreateOrOpen)
        .expect("create_or_open");
    assert!(h3.mapped_size() >= 256);
}

// Port of ShmTest.MultipleHandles — shared data visibility
#[test]
fn multiple_handles_shared_data() {
    let name = unique_name("multiple_handles");
    ShmHandle::unlink_by_name(&name);

    let h1 = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen)
        .expect("acquire 1");
    let h2 = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen)
        .expect("acquire 2");

    // Write through h1, read through h2
    unsafe {
        let ptr1 = h1.as_mut_ptr() as *mut i32;
        *ptr1 = 12345;

        let ptr2 = h2.as_ptr() as *const i32;
        assert_eq!(*ptr2, 12345);
    }
}

// Port of ShmTest.LargeSegment
#[test]
fn large_segment() {
    let name = unique_name("large_segment");
    ShmHandle::unlink_by_name(&name);

    let size = 10 * 1024 * 1024; // 10 MB
    let shm = ShmHandle::acquire(&name, size, ShmOpenMode::CreateOrOpen)
        .expect("acquire 10MB");
    assert!(shm.mapped_size() >= size);

    // Write a pattern to a portion
    unsafe {
        let mem = shm.as_mut_ptr();
        for i in 0..1024 {
            *mem.add(i) = (i % 256) as u8;
        }
    }

    // Verify pattern
    unsafe {
        let mem = shm.as_ptr();
        for i in 0..1024 {
            assert_eq!(*mem.add(i), (i % 256) as u8, "mismatch at byte {i}");
        }
    }
}

// Port of ShmTest.HandleClearStorage
#[test]
fn handle_clear_storage() {
    let name = unique_name("handle_clear_storage");
    ShmHandle::unlink_by_name(&name);

    {
        let _shm = ShmHandle::acquire(&name, 256, ShmOpenMode::CreateOrOpen)
            .expect("acquire");
    }
    // After drop, unlink should have happened (ref_count was 1).
    // Verify we can't open it.
    let result = ShmHandle::acquire(&name, 256, ShmOpenMode::Open);
    assert!(result.is_err(), "should not be able to open after last handle dropped");
}

// Additional: empty name should fail
#[test]
fn empty_name_fails() {
    let result = ShmHandle::acquire("", 256, ShmOpenMode::CreateOrOpen);
    assert!(result.is_err());
}

// Additional: zero size should fail
#[test]
fn zero_size_fails() {
    let result = ShmHandle::acquire("zero_size_test", 0, ShmOpenMode::CreateOrOpen);
    assert!(result.is_err());
}

// Additional: create exclusive should fail if already exists
#[test]
fn create_exclusive_fails_if_exists() {
    let name = unique_name("create_excl");
    ShmHandle::unlink_by_name(&name);

    let _h1 = ShmHandle::acquire(&name, 256, ShmOpenMode::Create)
        .expect("first create");
    let result = ShmHandle::acquire(&name, 256, ShmOpenMode::Create);
    assert!(result.is_err(), "exclusive create should fail when segment already exists");
}

// Additional: open after unlink should fail
#[test]
fn open_after_unlink_fails() {
    let name = unique_name("open_after_unlink");
    ShmHandle::unlink_by_name(&name);

    let shm = ShmHandle::acquire(&name, 256, ShmOpenMode::CreateOrOpen)
        .expect("create");
    shm.unlink(); // force-remove the backing file

    // A new open-only attempt should fail (backing file is gone)
    let result = ShmHandle::acquire(&name, 256, ShmOpenMode::Open);
    assert!(result.is_err());
}

// Additional: ref count across multiple opens
#[test]
fn ref_count_three_handles() {
    let name = unique_name("ref_count_3");
    ShmHandle::unlink_by_name(&name);

    let h1 = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen).unwrap();
    assert_eq!(h1.ref_count(), 1);

    let h2 = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen).unwrap();
    assert_eq!(h1.ref_count(), 2);

    let h3 = ShmHandle::acquire(&name, 512, ShmOpenMode::CreateOrOpen).unwrap();
    assert_eq!(h1.ref_count(), 3);

    drop(h3);
    assert_eq!(h1.ref_count(), 2);

    drop(h2);
    assert_eq!(h1.ref_count(), 1);

    drop(h1);
}

// Additional: data persistence across handles
#[test]
fn data_persistence() {
    let name = unique_name("data_persist");
    ShmHandle::unlink_by_name(&name);

    let payload = b"persistent payload 123456789";

    {
        let shm = ShmHandle::acquire(&name, 4096, ShmOpenMode::CreateOrOpen).unwrap();
        unsafe {
            std::ptr::copy_nonoverlapping(payload.as_ptr(), shm.as_mut_ptr(), payload.len());
        }
        // Don't drop — keep the ref count alive by leaking (we'll open another handle first)
        // Actually, we need the segment to survive. With create_or_open both will work.
        // Create a second handle to keep the segment alive
        let _shm2 = ShmHandle::acquire(&name, 4096, ShmOpenMode::CreateOrOpen).unwrap();
        drop(shm);
        // _shm2 keeps segment alive

        let shm3 = ShmHandle::acquire(&name, 4096, ShmOpenMode::CreateOrOpen).unwrap();
        let read_back = unsafe { std::slice::from_raw_parts(shm3.as_ptr(), payload.len()) };
        assert_eq!(read_back, payload);
    }
}

// Additional: various sizes
#[test]
fn various_sizes() {
    for &size in &[1usize, 4, 7, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128,
                   255, 256, 512, 1023, 1024, 4096, 8192, 65536] {
        let name = unique_name(&format!("size_{size}"));
        ShmHandle::unlink_by_name(&name);

        let shm = ShmHandle::acquire(&name, size, ShmOpenMode::CreateOrOpen)
            .unwrap_or_else(|e| panic!("failed to acquire shm of size {size}: {e}"));
        assert!(shm.mapped_size() >= size, "mapped_size {} < requested {size}", shm.mapped_size());
    }
}
