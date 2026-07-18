project(test-ipc)

if(NOT MSVC)
  add_compile_options(
    -Wno-attributes 
    -Wno-missing-field-initializers 
    -Wno-unused-variable 
    -Wno-unused-function)
endif()

include_directories(
    ${THOTH_IPC_PROJECT_DIR}/include
    ${THOTH_IPC_PROJECT_DIR}/src
    ${THOTH_IPC_PROJECT_DIR}/test
    ${THOTH_IPC_PROJECT_DIR}/3rdparty)

# sync_abi.h includes the vendored a0 headers, which the ipc library only
# exposes as a PRIVATE include dir; tests including src headers need it too.
if(UNIX)
    include_directories(${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/platform/linux)
endif()

# Collect only new test files (exclude archive directory)
file(GLOB SRC_FILES
    ${THOTH_IPC_PROJECT_DIR}/test/test_*.cpp
    ${THOTH_IPC_PROJECT_DIR}/test/imp/*.cpp
    ${THOTH_IPC_PROJECT_DIR}/test/mem/*.cpp
    ${THOTH_IPC_PROJECT_DIR}/test/concur/*.cpp
    # ${THOTH_IPC_PROJECT_DIR}/test/profiler/*.cpp
    )
file(GLOB HEAD_FILES ${THOTH_IPC_PROJECT_DIR}/test/test_*.h)

# Ensure we don't include archived tests
list(FILTER SRC_FILES EXCLUDE REGEX "archive")
list(FILTER HEAD_FILES EXCLUDE REGEX "archive")

add_executable(${PROJECT_NAME} ${SRC_FILES} ${HEAD_FILES})

link_directories(${THOTH_IPC_PROJECT_DIR}/3rdparty/gperftools)
target_link_libraries(${PROJECT_NAME} gtest gtest_main thoth_ipc)

# Cross-language round-trip harness (C++ endpoint). Uniform CLI shared with the
# Rust and Swift harnesses; driven by tools/xlang-runner. See
# context/xlang-channel-abi.md.
add_executable(xlang_ipc ${THOTH_IPC_PROJECT_DIR}/test/xlang/xlang.cpp)
target_include_directories(xlang_ipc PRIVATE ${THOTH_IPC_PROJECT_DIR}/include)
target_link_libraries(xlang_ipc thoth_ipc)
set_target_properties(xlang_ipc PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# Async (Layer 2) endpoint of the same harness — only when stdexec is enabled.
# ipc propagates STDEXEC::stdexec + THOTH_IPC_STDEXEC publicly, so linking ipc is
# enough. Proves the notify+reactor readiness path wakes cross-process, and
# (paired with the port notify sources) that a port send wakes C++ async_recv.
if(THOTH_IPC_STDEXEC)
    add_executable(xasync ${THOTH_IPC_PROJECT_DIR}/test/xlang/xasync.cpp)
    target_include_directories(xasync PRIVATE ${THOTH_IPC_PROJECT_DIR}/include)
    target_link_libraries(xasync thoth_ipc)
    set_target_properties(xasync PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
endif()

# Coroutine async-receive harness (path b): stdexec-free, needs only Layer 1
# (the reactor is compiled under THOTH_IPC_NOTIFY_FD) + C++20/23 coroutines.
if(THOTH_IPC_NOTIFY_FD)
    add_executable(xcoro ${THOTH_IPC_PROJECT_DIR}/test/xlang/xcoro.cpp)
    target_include_directories(xcoro PRIVATE ${THOTH_IPC_PROJECT_DIR}/include)
    target_link_libraries(xcoro thoth_ipc)
    set_target_properties(xcoro PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
endif()
#target_link_libraries(${PROJECT_NAME} tcmalloc_minimal)
