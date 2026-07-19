//! Public module surface of the thoth-ipc Zig port, exposed via `b.addModule`
//! so consumers (e.g. sourcetrail_zig_indexer) can `@import("thoth-ipc")`.
//!
//! Only the primitives an out-of-process Sourcetrail indexer needs are
//! re-exported here: a named shared-memory segment, a named cross-process
//! mutex, and the byte-exact shm-name hashing that keeps the Zig frontend
//! wire-compatible with the C++ core.

const shm = @import("platform/shm.zig");
const mutex = @import("sync/mutex.zig");
const shmname = @import("platform/shmname.zig");

pub const ShmHandle = shm.ShmHandle;
pub const OpenMode = shm.OpenMode;
pub const ShmError = shm.ShmError;

pub const Mutex = mutex.Mutex;

pub const makeShmName = shmname.makeShmName;
pub const fnv1a64 = shmname.fnv1a64;
pub const shm_name_max = shmname.shm_name_max;

test {
    _ = shm;
    _ = mutex;
    _ = shmname;
}
