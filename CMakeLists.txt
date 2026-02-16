cmake_minimum_required(VERSION 3.30)
project(cpp-ipc VERSION 1.4.1)

option(LIBIPC_BUILD_TESTS       "Build all of libipc's own tests."                      OFF)
option(LIBIPC_BUILD_DEMOS       "Build all of libipc's own demos."                      OFF)
option(LIBIPC_BUILD_BENCHMARKS  "Build IPC benchmarks."                                 OFF)
option(LIBIPC_BUILD_SHARED_LIBS "Build shared libraries (DLLs)."                        OFF)
option(LIBIPC_USE_STATIC_CRT    "Set to ON to build with static CRT on Windows (/MT)."  OFF)
option(LIBIPC_CODECOV           "Build with unit test coverage."                        OFF)

# Shorten POSIX shm/semaphore names via hashing when they exceed this limit.
# Set to 0 to disable (zero cost). Auto-enabled on macOS (PSHMNAMLEN = 31).
if(NOT DEFINED LIBIPC_SHM_NAME_MAX)
    if(APPLE)
        set(LIBIPC_SHM_NAME_MAX 31 CACHE STRING "Max POSIX shm name length (0 = no limit).")
    else()
        set(LIBIPC_SHM_NAME_MAX 0  CACHE STRING "Max POSIX shm name length (0 = no limit).")
    endif()
endif()

option(LIBIPC_USE_FILE_SHM      "Use file-backed mmap instead of shm_open (avoids PSHMNAMLEN)." OFF)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -DNDEBUG")
if(NOT MSVC)
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O2")
endif()

# Code coverage support
if (LIBIPC_CODECOV AND NOT MSVC)
    add_compile_options(--coverage)
    add_link_options(-lgcov --coverage)
endif()

if (MSVC)
    set(CompilerFlags
        CMAKE_CXX_FLAGS
        CMAKE_CXX_FLAGS_DEBUG
        CMAKE_CXX_FLAGS_RELEASE
        CMAKE_C_FLAGS
        CMAKE_C_FLAGS_DEBUG
        CMAKE_C_FLAGS_RELEASE
        )
    if (LIBIPC_USE_STATIC_CRT)
        foreach(CompilerFlag ${CompilerFlags})
            string(REPLACE "/MD" "/MT" ${CompilerFlag} "${${CompilerFlag}}")
            string(REPLACE "/MDd" "/MTd" ${CompilerFlag} "${${CompilerFlag}}")
        endforeach()
    else()
        foreach(CompilerFlag ${CompilerFlags})
            string(REPLACE "/MT" "/MD" ${CompilerFlag} "${${CompilerFlag}}")
            string(REPLACE "/MTd" "/MDd" ${CompilerFlag} "${${CompilerFlag}}")
        endforeach()
    endif()
endif()

set(LIBRARY_OUTPUT_PATH    ${CMAKE_BINARY_DIR}/bin)
set(EXECUTABLE_OUTPUT_PATH ${CMAKE_BINARY_DIR}/bin)
set(LIBIPC_PROJECT_DIR     ${PROJECT_SOURCE_DIR})

# Unicode Support
add_definitions(-DUNICODE -D_UNICODE)

add_subdirectory(src)

if (LIBIPC_BUILD_TESTS)
    include(FetchContent)
    FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.17.0
    )
    if (LIBIPC_USE_STATIC_CRT)
        set(gtest_force_shared_crt OFF CACHE BOOL "" FORCE)
    else()
        set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    endif()
    FetchContent_MakeAvailable(googletest)
    add_subdirectory(test)
endif()

if (LIBIPC_BUILD_DEMOS)
    add_subdirectory(demo/chat)
    add_subdirectory(demo/msg_que)
    add_subdirectory(demo/send_recv)
    if (MSVC)
        add_subdirectory(demo/win_service/service)
        add_subdirectory(demo/win_service/client)
    else()
        add_subdirectory(demo/linux_service/service)
        add_subdirectory(demo/linux_service/client)
    endif()
endif()

if (LIBIPC_BUILD_BENCHMARKS)
    add_subdirectory(bench)
endif()

install(
    DIRECTORY "include/"
    DESTINATION "include"
)
