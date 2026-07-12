// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Thin C shims for variadic POSIX functions that Swift 6 cannot call directly.

#pragma once
#include <sys/types.h>
#include <sys/wait.h>
#include <mach/thread_policy.h>
// Darwin libnotify (Layer 1 async-receive notify backend): notify_post /
// notify_register_file_descriptor / notify_cancel are not re-exported by the
// Swift Darwin module, so surface them here for `import LibIPCShim`.
#include <notify.h>

int libipc_shm_open_create(const char *name, mode_t mode);
int libipc_shm_open_open(const char *name, mode_t mode);

// waitpid status predicates (macros not importable into Swift)
static inline int libipc_wifexited(int s)   { return WIFEXITED(s); }
static inline int libipc_wexitstatus(int s) { return WEXITSTATUS(s); }
static inline int libipc_wifsignaled(int s) { return WIFSIGNALED(s); }
static inline int libipc_wtermsig(int s)    { return WTERMSIG(s); }

// Mach RT policy constant (not always importable as a Swift literal)
static inline unsigned int libipc_thread_time_constraint_policy_count(void) {
    return THREAD_TIME_CONSTRAINT_POLICY_COUNT;
}
