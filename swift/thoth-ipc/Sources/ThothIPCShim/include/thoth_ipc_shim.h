// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Thin C shims for variadic POSIX functions that Swift 6 cannot call directly,
// and for the platform sync code Swift reuses from C (linux_a0 on Linux).

#pragma once
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/wait.h>
#if defined(__APPLE__)
#include <mach/thread_policy.h>
// Darwin libnotify (Layer 1 async-receive notify backend): notify_post /
// notify_register_file_descriptor / notify_cancel are not re-exported by the
// Swift Darwin module, so surface them here for `import ThothIPCShim`.
#include <notify.h>
#endif

int thoth_ipc_shm_open_create(const char *name, mode_t mode);
int thoth_ipc_shm_open_open(const char *name, mode_t mode);

// The C standard streams. Glibc declares them as mutable globals, which Swift 6
// code cannot read; these return them.
static inline FILE *thoth_ipc_stdout(void) { return stdout; }
static inline FILE *thoth_ipc_stderr(void) { return stderr; }

// waitpid status predicates (macros not importable into Swift)
static inline int thoth_ipc_wifexited(int s)   { return WIFEXITED(s); }
static inline int thoth_ipc_wexitstatus(int s) { return WEXITSTATUS(s); }
static inline int thoth_ipc_wifsignaled(int s) { return WIFSIGNALED(s); }
static inline int thoth_ipc_wtermsig(int s)    { return WTERMSIG(s); }

#if defined(__APPLE__)
// Mach RT policy constant (not always importable as a Swift literal)
static inline unsigned int thoth_ipc_thread_time_constraint_policy_count(void) {
    return THREAD_TIME_CONSTRAINT_POLICY_COUNT;
}
#endif

#if defined(__linux__)
// linux_a0: the vendored alephzero robust, priority-inheriting futex mutex
// (a0_mtx_t) and requeue-PI condition (a0_cnd_t) that C++ and Rust run on
// Linux, compiled from the same sources (linux_sync.c). Pointers are the shared
// payloads; results are errno values (0, ETIMEDOUT, EOWNERDEAD,
// ENOTRECOVERABLE, EDEADLK, ...). A negative timeout waits forever.
enum { THOTH_A0_MTX_SIZE = 24, THOTH_A0_CND_SIZE = 4 };
int thoth_a0_mtx_lock(void *mtx, int64_t timeout_ns);
int thoth_a0_mtx_trylock(void *mtx);
int thoth_a0_mtx_consistent(void *mtx);
int thoth_a0_mtx_unlock(void *mtx);
int thoth_a0_cnd_wait(void *cnd, void *mtx, int64_t timeout_ns);
int thoth_a0_cnd_signal(void *cnd, void *mtx);
int thoth_a0_cnd_broadcast(void *cnd, void *mtx);

// write(2) that never raises SIGPIPE (C++ notify_sigpipe_guard), for the FIFO
// notify backend. Returns write's result, with errno set on failure.
long thoth_ipc_write_nosigpipe(int fd, const void *buf, unsigned long len);

// sem_open(name, O_CREAT, mode, value), which Swift cannot call (variadic).
// NULL (glibc's SEM_FAILED) on failure.
void *thoth_ipc_sem_open_create(const char *name, mode_t mode, unsigned int value);
#endif
