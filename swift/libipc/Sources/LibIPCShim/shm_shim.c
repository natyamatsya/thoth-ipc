// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Thin C shims for variadic POSIX functions that Swift 6 cannot call directly.

#include <sys/mman.h>
#include <fcntl.h>
#include <sys/stat.h>

int libipc_shm_open_create(const char *name, mode_t mode) {
    return shm_open(name, O_RDWR | O_CREAT | O_EXCL, mode);
}

int libipc_shm_open_create_or_open(const char *name, mode_t mode) {
    return shm_open(name, O_RDWR | O_CREAT | O_EXCL, mode);
}

int libipc_shm_open_open(const char *name, mode_t mode) {
    return shm_open(name, O_RDWR, mode);
}
