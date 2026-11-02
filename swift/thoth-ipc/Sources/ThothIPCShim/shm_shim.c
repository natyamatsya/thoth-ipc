// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Thin C shims for variadic POSIX functions that Swift 6 cannot call directly,
// and for fstat, which not every glibc exposes to Swift as a function.

#include <sys/mman.h>
#include <fcntl.h>
#include <sys/stat.h>

int thoth_ipc_shm_open_create(const char *name, mode_t mode) {
    return shm_open(name, O_RDWR | O_CREAT | O_EXCL, mode);
}

int thoth_ipc_shm_open_create_or_open(const char *name, mode_t mode) {
    return shm_open(name, O_RDWR | O_CREAT | O_EXCL, mode);
}

int thoth_ipc_shm_open_open(const char *name, mode_t mode) {
    return shm_open(name, O_RDWR, mode);
}

long long thoth_ipc_shm_size(int fd) {
    struct stat st;
    return fstat(fd, &st) == 0 ? (long long)st.st_size : -1;
}
