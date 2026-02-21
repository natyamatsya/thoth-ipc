// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Thin C shims for variadic POSIX functions that Swift 6 cannot call directly.

#pragma once
#include <sys/types.h>

int libipc_shm_open_create(const char *name, mode_t mode);
int libipc_shm_open_open(const char *name, mode_t mode);
