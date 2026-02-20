// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Typed FlatBuffer message wrapper and builder.
// Port of cpp-ipc/include/libipc/proto/message.h.

use flatbuffers::{
    root, FlatBufferBuilder, Follow, ForwardsUOffset, Verifiable, Verifier, VerifierOptions,
    WIPOffset,
};

use crate::buffer::IpcBuffer;

// ---------------------------------------------------------------------------
// message<T> — zero-copy typed view over a received IpcBuffer
// ---------------------------------------------------------------------------

/// A received FlatBuffer message with typed access.
///
/// `T` must be a FlatBuffers-generated table type (e.g. `MyProtocol::ControlMsg`).
/// The buffer is owned; access to the root is a zero-copy pointer cast.
///
/// Port of `ipc::proto::message<T>` from the C++ libipc library.
pub struct Message<T> {
    buf: IpcBuffer,
    _marker: std::marker::PhantomData<T>,
}

impl<T> Message<T> {
    /// Wrap a received buffer. Use [`empty`] to construct an empty message.
    pub fn new(buf: IpcBuffer) -> Self {
        Self {
            buf,
            _marker: std::marker::PhantomData,
        }
    }

    /// An empty (invalid) message.
    pub fn empty() -> Self {
        Self::new(IpcBuffer::new())
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// Raw byte slice of the FlatBuffer.
    pub fn data(&self) -> &[u8] {
        self.buf.data()
    }

    pub fn size(&self) -> usize {
        self.buf.len()
    }
}

impl<T> Message<T>
where
    T: for<'a> Follow<'a> + Verifiable,
{
    /// Verify buffer integrity. Call this on untrusted data before accessing.
    pub fn verify(&self) -> bool {
        if self.buf.is_empty() {
            return false;
        }
        let opts = VerifierOptions::default();
        let mut v = Verifier::new(&opts, self.buf.data());
        <ForwardsUOffset<T>>::run_verifier(&mut v, 0).is_ok()
    }

    /// Zero-copy access to the deserialized root table.
    /// Returns `None` if the buffer is empty.
    /// The returned reference borrows from `self`.
    pub fn root(&self) -> Option<<T as Follow<'_>>::Inner> {
        if self.buf.is_empty() {
            return None;
        }
        root::<T>(self.buf.data()).ok()
    }
}

// ---------------------------------------------------------------------------
// Builder — wraps FlatBufferBuilder for ergonomic message construction
// ---------------------------------------------------------------------------

/// Helper for building a FlatBuffer message to send over a channel.
///
/// Usage:
/// ```ignore
/// let mut b = Builder::new(1024);
/// let name = b.fbb().create_string("hello");
/// let msg = MyTable::create(b.fbb(), &MyTableArgs { name: Some(name) });
/// b.finish(msg);
/// ch.send(b.data(), b.size(), 1000)?;
/// ```
///
/// Port of `ipc::proto::builder` from the C++ libipc library.
pub struct Builder {
    fbb: FlatBufferBuilder<'static>,
    finished: bool,
}

impl Builder {
    pub fn new(initial_size: usize) -> Self {
        Self {
            fbb: FlatBufferBuilder::with_capacity(initial_size),
            finished: false,
        }
    }

    /// Access the inner `FlatBufferBuilder` to create strings, vectors, tables, etc.
    pub fn fbb(&mut self) -> &mut FlatBufferBuilder<'static> {
        &mut self.fbb
    }

    /// Finish the buffer with the given root offset.
    pub fn finish<T>(&mut self, root: WIPOffset<T>) {
        self.fbb.finish(root, None);
        self.finished = true;
    }

    /// Finish with a 4-byte file identifier from the schema.
    pub fn finish_with_id<T>(&mut self, root: WIPOffset<T>, file_id: &str) {
        self.fbb.finish(root, Some(file_id));
        self.finished = true;
    }

    /// Pointer to the finished buffer bytes. Returns empty slice if not yet finished.
    pub fn data(&self) -> &[u8] {
        if !self.finished {
            return &[];
        }
        self.fbb.finished_data()
    }

    /// Size of the finished buffer. Returns 0 if not yet finished.
    pub fn size(&self) -> usize {
        self.data().len()
    }

    /// Reset the builder for reuse.
    pub fn clear(&mut self) {
        self.fbb.reset();
        self.finished = false;
    }
}

impl Default for Builder {
    fn default() -> Self {
        Self::new(1024)
    }
}
