// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Standalone smoke test for the `thoth.ipc` C++20 named module: proves that
// `import thoth.ipc;` compiles and that the exported surface round-trips a
// message. Not a gtest — exits nonzero on any failure.
//
// GCC PR114795: every #include (std or thoth macro header) must precede the
// import; never include a header after `import thoth.ipc;`.
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

// Modules cannot export macros; THOTH_IPC_LOG / THOTH_IPC_SCOPE_EXIT stay
// available only via their headers.
#include "thoth-ipc/imp/log.h"
#include "thoth-ipc/imp/scope_exit.h"

import thoth.ipc;

namespace {

int failures = 0;

bool check(bool ok, char const *what) {
  if (!ok) {
    std::fprintf(stderr, "module_smoke: FAIL: %s\n", what);
    ++failures;
  }
  return ok;
}

// send(std::string) transmits size()+1 bytes including the terminator.
bool matches(thoth::buffer const &got, std::string const &expected) {
  // Non-owning view (no destructor passed); compares via the hidden-friend
  // operator==, which the module makes reachable through ADL only.
  thoth::buffer want{const_cast<char *>(expected.c_str()), expected.size() + 1};
  return !got.empty() && got == want;
}

template <typename Chan>
void round_trip(char const *name, char const *what) {
  // Declared before the channels so it runs after their destructors.
  THOTH_IPC_SCOPE_EXIT(guard) = [name] { Chan::clear_storage(name); };
  Chan tx{name, thoth::sender};
  Chan rx{name, thoth::receiver};
  if (!check(tx.valid() && rx.valid(), what)) return;
  if (!check(tx.wait_for_recv(1, 5000), "wait_for_recv")) return;
  std::string const msg = std::string("hello-from-module-") + what;
  std::thread t([&] { check(tx.send(msg), "send"); });
  thoth::buffer got = rx.recv(5000);
  t.join();
  check(matches(got, msg), "recv content");
}

} // namespace

int main() {
  THOTH_IPC_LOG("module_smoke");

  // Exported constants and types.
  static_assert(thoth::default_timeout == 100);
  static_assert(thoth::invalid_value == 0xffffffffu);
  static_assert(sizeof(thoth::uint_t<64>) == 8);
  static_assert(thoth::relat_trait<thoth::wr<thoth::relat::single,
                                             thoth::relat::multi,
                                             thoth::trans::broadcast>>::is_broadcast);
  (void)thoth::invalid_wait_handle;

  round_trip<thoth::route>("thoth-module-smoke-route", "route");
  round_trip<thoth::channel>("thoth-module-smoke-channel", "channel");

  {
    thoth::sync::mutex m{"thoth-module-smoke-mtx"};
    check(m.valid(), "mutex valid");
    check(m.lock(1000), "mutex lock");
    check(m.unlock(), "mutex unlock");
    m.clear();
  }
  {
    thoth::sync::semaphore s{"thoth-module-smoke-sem"};
    check(s.valid(), "semaphore valid");
    check(s.post(), "semaphore post");
    check(s.wait(1000), "semaphore wait");
    s.clear();
  }
  {
    thoth::shm::handle h{"thoth-module-smoke-shm", 4096};
    check(h.valid(), "shm valid");
    check(h.get() != nullptr, "shm mem");
    h.clear();
  }
  {
    thoth::spin_lock sl;
    sl.lock();
    sl.unlock();
  }
  {
    thoth::rw_lock rw;
    rw.lock_shared();
    rw.unlock_shared();
    rw.lock();
    rw.unlock();
  }

  if (failures != 0) {
    log.error("module_smoke failed");
    std::fprintf(stderr, "module_smoke: %d failure(s)\n", failures);
    return 1;
  }
  log.info("module_smoke ok");
  std::puts("module_smoke: OK");
  return 0;
}
