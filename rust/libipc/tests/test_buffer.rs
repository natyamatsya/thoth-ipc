// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_buffer.cpp

use libipc::IpcBuffer;

// Port of BufferTest.DefaultConstructor
#[test]
fn default_constructor() {
    let buf = IpcBuffer::new();
    assert!(buf.is_empty());
    assert_eq!(buf.len(), 0);
    assert!(buf.data().is_empty());
}

// Port of BufferTest.ConstructorFromSlice
#[test]
fn from_slice() {
    let data = b"Hello, World!";
    let buf = IpcBuffer::from_slice(data);
    assert!(!buf.is_empty());
    assert_eq!(buf.len(), data.len());
    assert_eq!(buf.data(), data);
}

// Port of BufferTest.ConstructorFromStr
#[test]
fn from_str() {
    let buf = IpcBuffer::from_str("Hello");
    assert!(!buf.is_empty());
    assert_eq!(buf.len(), 6); // includes null terminator
    assert_eq!(buf.data()[..5], *b"Hello");
    assert_eq!(buf.data()[5], 0);
}

// Port of BufferTest.MoveConstructor (clone in Rust)
#[test]
fn clone() {
    let buf1 = IpcBuffer::from_slice(b"Clone test");
    let buf2 = buf1.clone();
    assert_eq!(buf1, buf2);
    assert!(!buf2.is_empty());
    assert_eq!(buf2.len(), 10);
}

// Port of BufferTest.Swap
#[test]
fn swap() {
    let mut buf1 = IpcBuffer::from_slice(b"Buffer 1");
    let mut buf2 = IpcBuffer::from_slice(b"Buffer 2 longer");

    let len1 = buf1.len();
    let len2 = buf2.len();

    buf1.swap(&mut buf2);

    assert_eq!(buf1.len(), len2);
    assert_eq!(buf2.len(), len1);
    assert_eq!(buf1.data(), b"Buffer 2 longer");
    assert_eq!(buf2.data(), b"Buffer 1");
}

// Port of BufferTest.EmptyMethod
#[test]
fn empty_method() {
    let buf1 = IpcBuffer::new();
    assert!(buf1.is_empty());

    let buf2 = IpcBuffer::from_slice(b"data");
    assert!(!buf2.is_empty());
}

// Port of BufferTest.ToVector
#[test]
fn to_vec() {
    let data: &[u8] = &[10, 20, 30, 40, 50];
    let buf = IpcBuffer::from_slice(data);
    let vec = buf.to_vec();
    assert_eq!(vec.len(), 5);
    assert_eq!(vec, data);
}

// Port of BufferTest.EqualityOperator
#[test]
fn equality() {
    let buf1 = IpcBuffer::from_slice(&[1, 2, 3, 4, 5]);
    let buf2 = IpcBuffer::from_slice(&[1, 2, 3, 4, 5]);
    let buf3 = IpcBuffer::from_slice(&[5, 4, 3, 2, 1]);

    assert_eq!(buf1, buf2);
    assert_ne!(buf1, buf3);
}

// Port of BufferTest.EqualityWithDifferentSizes
#[test]
fn equality_different_sizes() {
    let buf1 = IpcBuffer::from_slice(&[1, 2, 3, 4, 5]);
    let buf2 = IpcBuffer::from_slice(&[1, 2, 3]);

    assert_ne!(buf1, buf2);
}

// Port of BufferTest.EmptyBuffersComparison
#[test]
fn empty_buffers_comparison() {
    let buf1 = IpcBuffer::new();
    let buf2 = IpcBuffer::new();

    assert_eq!(buf1, buf2);
}

// Port of BufferTest.LargeBuffer
#[test]
fn large_buffer() {
    let large_size = 1024 * 1024; // 1MB
    let data: Vec<u8> = (0..large_size).map(|i| (i % 256) as u8).collect();
    let buf = IpcBuffer::from_slice(&data);

    assert!(!buf.is_empty());
    assert_eq!(buf.len(), large_size);

    for i in 0..100 {
        assert_eq!(buf.data()[i], (i % 256) as u8);
    }
}

// Port of BufferTest.MultipleMoves
#[test]
fn into_vec_and_back() {
    let original = IpcBuffer::from_slice(b"Multi-move");
    let vec = original.into_vec();
    let buf = IpcBuffer::from_vec(vec);
    assert!(!buf.is_empty());
    assert_eq!(buf.data(), b"Multi-move");
}

// Port of BufferTest.FromString
#[test]
fn from_string() {
    let buf: IpcBuffer = String::from("test").into();
    assert_eq!(buf.len(), 5); // "test" + null
    assert_eq!(&buf.data()[..4], b"test");
}

// Port of BufferTest.FromSliceTrait
#[test]
fn from_slice_trait() {
    let data: &[u8] = &[1, 2, 3];
    let buf: IpcBuffer = data.into();
    assert_eq!(buf.data(), &[1, 2, 3]);
}

// Port of BufferTest.FromVecTrait
#[test]
fn from_vec_trait() {
    let v = vec![10u8, 20, 30];
    let buf: IpcBuffer = v.into();
    assert_eq!(buf.data(), &[10, 20, 30]);
}

// Port of BufferTest.DataMut
#[test]
fn data_mut() {
    let mut buf = IpcBuffer::from_slice(&[1, 2, 3]);
    buf.data_mut()[0] = 99;
    assert_eq!(buf.data()[0], 99);
}

// Port of BufferTest.Default
#[test]
fn default() {
    let buf = IpcBuffer::default();
    assert!(buf.is_empty());
}
