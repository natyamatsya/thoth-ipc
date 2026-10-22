// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Linux sync for Swift: the linux_a0 mutex and condition of C++
// platform/linux/{mutex,condition}.h over the vendored alephzero code, with
// errno results, and the SIGPIPE-safe FIFO write of C++ notify_source.

#if defined(__linux__)

#include "thoth_ipc_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <semaphore.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

#include "a0/err_macro.h"
#include "a0/mtx.h"
#include "a0/time.h"

_Static_assert(sizeof(a0_mtx_t) == THOTH_A0_MTX_SIZE, "a0_mtx_t layout (abi.json a0_mtx)");
_Static_assert(sizeof(a0_cnd_t) == THOTH_A0_CND_SIZE, "a0_cnd_t layout (abi.json a0_cnd)");

// C++ linux_::detail::calc_wait_time: a deadline `timeout_ns` from now on a0's
// monotonic clock.
static int deadline_in(int64_t timeout_ns, a0_time_mono_t *out) {
    a0_time_mono_t now;
    int eno = A0_SYSERR(a0_time_mono_now(&now));
    if (eno != 0) return eno;
    return A0_SYSERR(a0_time_mono_add(now, timeout_ns < 0 ? 0 : timeout_ns, out));
}

int thoth_a0_mtx_lock(void *mtx, int64_t timeout_ns) {
    if (timeout_ns < 0) return A0_SYSERR(a0_mtx_lock((a0_mtx_t *)mtx));
    a0_time_mono_t deadline;
    int eno = deadline_in(timeout_ns, &deadline);
    if (eno != 0) return eno;
    return A0_SYSERR(a0_mtx_timedlock((a0_mtx_t *)mtx, deadline));
}

int thoth_a0_mtx_trylock(void *mtx) { return A0_SYSERR(a0_mtx_trylock((a0_mtx_t *)mtx)); }
int thoth_a0_mtx_consistent(void *mtx) { return A0_SYSERR(a0_mtx_consistent((a0_mtx_t *)mtx)); }
int thoth_a0_mtx_unlock(void *mtx) { return A0_SYSERR(a0_mtx_unlock((a0_mtx_t *)mtx)); }

int thoth_a0_cnd_wait(void *cnd, void *mtx, int64_t timeout_ns) {
    if (timeout_ns < 0) return A0_SYSERR(a0_cnd_wait((a0_cnd_t *)cnd, (a0_mtx_t *)mtx));
    a0_time_mono_t deadline;
    int eno = deadline_in(timeout_ns, &deadline);
    if (eno != 0) return eno;
    return A0_SYSERR(a0_cnd_timedwait((a0_cnd_t *)cnd, (a0_mtx_t *)mtx, deadline));
}

int thoth_a0_cnd_signal(void *cnd, void *mtx) {
    return A0_SYSERR(a0_cnd_signal((a0_cnd_t *)cnd, (a0_mtx_t *)mtx));
}

int thoth_a0_cnd_broadcast(void *cnd, void *mtx) {
    return A0_SYSERR(a0_cnd_broadcast((a0_cnd_t *)cnd, (a0_mtx_t *)mtx));
}

// C++ notify_sigpipe_guard around the write: Linux has no per-fd
// F_SETNOSIGPIPE, so block SIGPIPE on this thread and consume one we caused.
long thoth_ipc_write_nosigpipe(int fd, const void *buf, unsigned long len) {
    sigset_t s, old;
    sigemptyset(&s);
    sigaddset(&s, SIGPIPE);
    int blocked = pthread_sigmask(SIG_BLOCK, &s, &old) == 0;
    long n = (long)write(fd, buf, len);
    int saved = errno;
    sigset_t pend;
    if (sigpending(&pend) == 0 && sigismember(&pend, SIGPIPE)) {
        struct timespec zero = {0, 0};
        sigtimedwait(&s, NULL, &zero);
    }
    if (blocked) pthread_sigmask(SIG_SETMASK, &old, NULL);
    errno = saved;
    return n;
}

void *thoth_ipc_sem_open_create(const char *name, mode_t mode, unsigned int value) {
    sem_t *s = sem_open(name, O_CREAT, mode, value);
    return s == SEM_FAILED ? NULL : s;
}

#endif
