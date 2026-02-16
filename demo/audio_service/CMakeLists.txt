# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

project(audio_service_demo)

# Generate C++ header from FlatBuffers schema
set(FBS_FILE ${CMAKE_CURRENT_SOURCE_DIR}/audio_protocol.fbs)
set(FBS_GEN  ${CMAKE_CURRENT_BINARY_DIR}/audio_protocol_generated.h)

add_custom_command(
    OUTPUT  ${FBS_GEN}
    COMMAND flatc --cpp -o ${CMAKE_CURRENT_BINARY_DIR} ${FBS_FILE}
    DEPENDS ${FBS_FILE} flatc
    COMMENT "Generating FlatBuffers header from audio_protocol.fbs"
)
add_custom_target(audio_protocol_gen DEPENDS ${FBS_GEN})

# Host executable
add_executable(audio_host host.cpp)
add_dependencies(audio_host audio_protocol_gen)
target_include_directories(audio_host PRIVATE
    ${LIBIPC_PROJECT_DIR}/include
    ${LIBIPC_PROJECT_DIR}/3rdparty
    ${CMAKE_CURRENT_BINARY_DIR}
)
target_link_libraries(audio_host ipc flatbuffers)

# Service executable
add_executable(audio_service service.cpp)
add_dependencies(audio_service audio_protocol_gen)
target_include_directories(audio_service PRIVATE
    ${LIBIPC_PROJECT_DIR}/include
    ${LIBIPC_PROJECT_DIR}/3rdparty
    ${CMAKE_CURRENT_BINARY_DIR}
)
target_link_libraries(audio_service ipc flatbuffers)
