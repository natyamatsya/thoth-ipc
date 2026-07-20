# C++20 module support (`import thoth.ipc;`)

thoth-ipc ships an opt-in C++20 named module, `thoth.ipc`, as an alternative
to `#include`-ing the headers. The approach follows
[sqlpp23](https://github.com/rbock/sqlpp23): the module interface unit
([`modules/thoth.ipc.cppm`](../modules/thoth.ipc.cppm)) includes the existing
headers in its global module fragment and re-exports the public names via
using-declarations. The library itself is unchanged — headers remain the
primary interface, and nothing about a default build differs when the option
is off.

## What the module covers

The always-on core surface:

- `thoth::route`, `thoth::channel`, `thoth::chan` / `chan_wrapper` / `chan_impl`
- `thoth::buffer` / `buff_t` (its `operator==`/`!=` are hidden friends, found via ADL)
- `def.h` types and constants (`relat`, `trans`, `wr`, `relat_trait`, `prefix`,
  `invalid_value`, `default_timeout`, …)
- `thoth::shm` (`handle`, `acquire`/`release`/`remove`, …)
- `thoth::sync::mutex` / `semaphore` / `condition`
- `thoth::spin_lock`, `thoth::rw_lock`, `thoth::yield`, `thoth::sleep`
- `wait_handle_t` / `invalid_wait_handle`

Not covered (keep using headers): the typed protocol layer (`proto/*`), the
stdexec async layer (`async_recv.h`, gated on `THOTH_IPC_STDEXEC`), allocators
(`mem/*`), `concur/*`, and everything under `imp/*`.

## Usage

```cpp
// Macros cannot be exported by modules — include their headers if you need
// THOTH_IPC_LOG / THOTH_IPC_SCOPE_EXIT / THOTH_IPC_EXPORT / detect_plat.h.
// IMPORTANT: every #include must come BEFORE the import (GCC PR114795, see
// caveats below).
#include <string>
#include "thoth-ipc/imp/log.h"

import thoth.ipc;

int main() {
    thoth::route r{"my-route", thoth::sender};
    r.send(std::string("hello"));
}
```

Build with:

```bash
cmake -S . -B build -G Ninja -DTHOTH_IPC_BUILD_MODULES=ON
cmake --build build
```

In-tree consumers link the `thoth_ipc_module` target; installed-package
consumers link `thoth-ipc::thoth_ipc_module`. Both propagate the include
directories, the `THOTH_IPC_*` public compile definitions, and the link
dependency on the compiled library.

The smoke test `test/modules/module_smoke.cpp` (built whenever the option is
on) is a working end-to-end example.

## Requirements

- CMake ≥ 3.28 (this repo already requires 3.30) **with the Ninja or
  "Ninja Multi-Config" generator** — CMake's module dependency scanning does
  not work with the Makefiles generator. The configure step enforces this.
- A compiler with usable C++20 modules + `clang-scan-deps` support:
  - Clang ≥ 17 (validated with Homebrew LLVM clang 22 on macOS).
  - **Apple Clang does not ship `clang-scan-deps`** as of Xcode 26/27 — on
    macOS use Homebrew LLVM and Apple's archiver:
    `-DCMAKE_CXX_COMPILER=$(brew --prefix llvm)/bin/clang++`
    `-DCMAKE_C_COMPILER=$(brew --prefix llvm)/bin/clang`
    `-DCMAKE_AR=/usr/bin/ar -DCMAKE_RANLIB=/usr/bin/ranlib`
    (Homebrew's default `llvm-ar` writes GNU-format archives that Apple's
    linker rejects.)
  - GCC ≥ 14. Note: sqlpp23 found GCC 15.2.1 miscompiles module builds while
    15.2.0 / 15.3.0 work — prefer 14.x or 15.3+.
  - MSVC is untested (configure warns and proceeds).

## Install layout

`cmake --install` ships the module *source*, not a BMI:

- `<prefix>/modules/thoth-ipc/thoth.ipc.cppm` — the interface unit
- `<prefix>/share/thoth-ipc/cxx-modules-thoth-ipc-targets.cmake` — generated
  next to the regular targets file; consumers' CMake (≥ 3.28, Ninja) compiles
  the `.cppm` themselves against their own flags. BMIs are not portable across
  compilers/flags, so none is installed (same policy as sqlpp23).

## Caveats

- **Include-before-import (GCC PR114795):** any header that ends up both
  `#include`d and reachable through `import thoth.ipc;` in one TU must be
  included *before* the import. Simplest rule: put all `#include`s first.
  See <https://gcc.gnu.org/bugzilla/show_bug.cgi?id=114795>.
- **Don't mix** `#include "thoth-ipc/ipc.h"` and `import thoth.ipc;` in the
  same TU — it is redundant, and the module's re-exported names can collide
  with the header's declarations.
- **Macros are not exported.** `THOTH_IPC_LOG`, `THOTH_IPC_SCOPE_EXIT`,
  `THOTH_IPC_EXPORT`, and the `detect_plat.h` platform/attribute macros are
  only available by including their headers (before the import).
- **Config must match:** the module interface unit is compiled in the same
  build tree with the same `THOTH_IPC_*` options as the library, so the
  exported surface always matches the compiled ABI (e.g. `THOTH_IPC_NOTIFY_FD`
  changes `native_wait_handle` behavior). Configure options once for both.
- The module target is a small static library (`libthoth_ipc_module.a`)
  containing the module initializer; it links `thoth_ipc` publicly, so linking
  `thoth_ipc_module` is all a consumer needs.
