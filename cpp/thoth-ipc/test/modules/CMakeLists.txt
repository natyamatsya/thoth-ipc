# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

# Standalone smoke test: proves `import thoth.ipc;` compiles and the exported
# surface round-trips a message (modeled on the xlang_ipc harness target).
# Built whenever THOTH_IPC_BUILD_MODULES is ON; no gtest dependency.
add_executable(module_smoke module_smoke.cpp)
# Include dirs and PUBLIC compile definitions propagate from thoth_ipc.
target_link_libraries(module_smoke PRIVATE thoth_ipc_module)
set_target_properties(module_smoke
    PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
