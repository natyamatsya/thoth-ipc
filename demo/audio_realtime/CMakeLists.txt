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

set_target_properties(rt_audio_host rt_audio_service PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
