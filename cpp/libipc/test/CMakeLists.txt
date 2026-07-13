project(test-ipc)

if(NOT MSVC)
  add_compile_options(
    -Wno-attributes 
    -Wno-missing-field-initializers 
    -Wno-unused-variable 
    -Wno-unused-function)
endif()

include_directories(
    ${LIBIPC_PROJECT_DIR}/include
    ${LIBIPC_PROJECT_DIR}/src
    ${LIBIPC_PROJECT_DIR}/test
    ${LIBIPC_PROJECT_DIR}/3rdparty)

# sync_abi.h includes the vendored a0 headers, which the ipc library only
# exposes as a PRIVATE include dir; tests including src headers need it too.
if(UNIX)
    include_directories(${LIBIPC_PROJECT_DIR}/src/libipc/platform/linux)
endif()

# Collect only new test files (exclude archive directory)
file(GLOB SRC_FILES
    ${LIBIPC_PROJECT_DIR}/test/test_*.cpp
    ${LIBIPC_PROJECT_DIR}/test/imp/*.cpp
    ${LIBIPC_PROJECT_DIR}/test/mem/*.cpp
    ${LIBIPC_PROJECT_DIR}/test/concur/*.cpp
    # ${LIBIPC_PROJECT_DIR}/test/profiler/*.cpp
    )
file(GLOB HEAD_FILES ${LIBIPC_PROJECT_DIR}/test/test_*.h)

# Ensure we don't include archived tests
list(FILTER SRC_FILES EXCLUDE REGEX "archive")
list(FILTER HEAD_FILES EXCLUDE REGEX "archive")

add_executable(${PROJECT_NAME} ${SRC_FILES} ${HEAD_FILES})

link_directories(${LIBIPC_PROJECT_DIR}/3rdparty/gperftools)
target_link_libraries(${PROJECT_NAME} gtest gtest_main ipc)

# Cross-language round-trip harness (C++ endpoint). Uniform CLI shared with the
# Rust and Swift harnesses; driven by tools/xlang-runner. See
# context/xlang-channel-abi.md.
add_executable(xlang_ipc ${LIBIPC_PROJECT_DIR}/test/xlang/xlang.cpp)
target_include_directories(xlang_ipc PRIVATE ${LIBIPC_PROJECT_DIR}/include)
target_link_libraries(xlang_ipc ipc)
set_target_properties(xlang_ipc PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# Async (Layer 2) endpoint of the same harness — only when stdexec is enabled.
# ipc propagates STDEXEC::stdexec + LIBIPC_STDEXEC publicly, so linking ipc is
# enough. Proves the notify+reactor readiness path wakes cross-process, and
# (paired with the port notify sources) that a port send wakes C++ async_recv.
if(LIBIPC_STDEXEC)
    add_executable(xasync ${LIBIPC_PROJECT_DIR}/test/xlang/xasync.cpp)
    target_include_directories(xasync PRIVATE ${LIBIPC_PROJECT_DIR}/include)
    target_link_libraries(xasync ipc)
    set_target_properties(xasync PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
endif()

# Coroutine async-receive harness (path b): stdexec-free, needs only Layer 1
# (the reactor is compiled under LIBIPC_NOTIFY_FD) + C++20/23 coroutines.
if(LIBIPC_NOTIFY_FD)
    add_executable(xcoro ${LIBIPC_PROJECT_DIR}/test/xlang/xcoro.cpp)
    target_include_directories(xcoro PRIVATE ${LIBIPC_PROJECT_DIR}/include)
    target_link_libraries(xcoro ipc)
    set_target_properties(xcoro PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
endif()
#target_link_libraries(${PROJECT_NAME} tcmalloc_minimal)
