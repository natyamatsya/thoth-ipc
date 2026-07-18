project(secure_pos)

file(GLOB SRC_FILES ./*.cpp)

add_executable(${PROJECT_NAME} ${SRC_FILES})

target_include_directories(${PROJECT_NAME} PRIVATE ${THOTH_IPC_PROJECT_DIR}/include)
target_link_libraries(${PROJECT_NAME} thoth_ipc)
set_target_properties(${PROJECT_NAME} PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
