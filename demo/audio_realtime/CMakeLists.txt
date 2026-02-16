# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

project(audio_realtime_demo)

add_executable(rt_audio_host host.cpp)
target_include_directories(rt_audio_host PRIVATE
    ${LIBIPC_PROJECT_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(rt_audio_host PRIVATE ipc)

add_executable(rt_audio_service service.cpp)
target_include_directories(rt_audio_service PRIVATE
    ${LIBIPC_PROJECT_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(rt_audio_service PRIVATE ipc)

# The service process is compiled as C++23 to demonstrate that process
# separation allows each component to use a different language standard.
# The host remains at the project default (C++17).
set_target_properties(rt_audio_service PROPERTIES
    CXX_STANDARD 23
    CXX_STANDARD_REQUIRED ON)

set_target_properties(rt_audio_host rt_audio_service PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
