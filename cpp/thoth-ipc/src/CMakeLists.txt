project(thoth_ipc)

set (PACKAGE_VERSION 0.1.0)

aux_source_directory(${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc SRC_FILES)
aux_source_directory(${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/sync SRC_FILES)
aux_source_directory(${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/platform SRC_FILES)
aux_source_directory(${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/imp SRC_FILES)
aux_source_directory(${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/mem SRC_FILES)
# execution/reactor.cpp compiles to an empty TU unless THOTH_IPC_STDEXEC is set.
aux_source_directory(${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/execution SRC_FILES)

file(GLOB HEAD_FILES
  ${THOTH_IPC_PROJECT_DIR}/include/thoth-ipc/*.h
  ${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/*.h
  ${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/*.inc
  ${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/circ/*.h
  ${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/memory/*.h
  ${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/platform/*.h
  ${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/utility/*.h)

if (THOTH_IPC_BUILD_SHARED_LIBS)
  add_library(${PROJECT_NAME} SHARED ${SRC_FILES} ${HEAD_FILES})
  target_compile_definitions(${PROJECT_NAME}
    INTERFACE
      THOTH_IPC_LIBRARY_SHARED_USING__
    PRIVATE
      THOTH_IPC_LIBRARY_SHARED_BUILDING__)
else()
  add_library(${PROJECT_NAME} STATIC ${SRC_FILES} ${HEAD_FILES})
endif()

# set output directory
set_target_properties(${PROJECT_NAME}
	PROPERTIES
	ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
	LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
	RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# set version
set_target_properties(${PROJECT_NAME}
    PROPERTIES
    VERSION ${PACKAGE_VERSION}
    SOVERSION 3)

target_include_directories(${PROJECT_NAME}
  PUBLIC
    "$<BUILD_INTERFACE:${THOTH_IPC_PROJECT_DIR}/include>"
    "$<INSTALL_INTERFACE:include>"
  PRIVATE ${THOTH_IPC_PROJECT_DIR}/src
          $<$<BOOL:UNIX>:${THOTH_IPC_PROJECT_DIR}/src/thoth-ipc/platform/linux>)

# The Linux platform code uses clockid_t and CLOCK_BOOTTIME/MONOTONIC/REALTIME.
# glibc only exposes clockid_t/CLOCK_* under the right feature-test macro when
# compiling as strict ISO C (-std=c17), and CLOCK_BOOTTIME specifically requires
# _GNU_SOURCE. (macOS exposes them unconditionally, so this is Linux-only.)
if(UNIX AND NOT APPLE)
  target_compile_definitions(${PROJECT_NAME} PRIVATE _GNU_SOURCE)
endif()

if(THOTH_IPC_SHM_NAME_MAX GREATER 0)
  target_compile_definitions(${PROJECT_NAME} PRIVATE THOTH_IPC_SHM_NAME_MAX=${THOTH_IPC_SHM_NAME_MAX})
endif()

if(WIN32)
  # Windows named-object namespace prefix (see top-level THOTH_IPC_WIN_OBJ_NAMESPACE).
  # PUBLIC so downstream TUs building notify/event names agree with the library.
  target_compile_definitions(${PROJECT_NAME} PUBLIC THOTH_IPC_WIN_OBJ_NS="${THOTH_IPC_WIN_OBJ_NAMESPACE}")
endif()

if(THOTH_IPC_USE_FILE_SHM)
  target_compile_definitions(${PROJECT_NAME} PRIVATE THOTH_IPC_USE_FILE_SHM)
endif()

if(APPLE AND THOTH_IPC_APPLE_APP_STORE_SAFE)
  target_compile_definitions(${PROJECT_NAME} PUBLIC THOTH_IPC_APPLE_APP_STORE_SAFE)
endif()

# Opt-in Layer 1 readiness handle (see notify.h). The public ABI
# (native_wait_handle) is stable regardless; the macro is PUBLIC so downstream
# TUs can feature-test it (#if defined(THOTH_IPC_NOTIFY_FD)) before relying on a
# functional handle. When OFF, native_wait_handle returns thoth::invalid_wait_handle.
if(THOTH_IPC_NOTIFY_FD)
  # Windows uses the named-Event backend (notify.h THOTH_IPC_NOTIFY_BACKEND_WINEVENT);
  # POSIX uses libnotify (Apple) or the FIFO backend. All are wired below.
  target_compile_definitions(${PROJECT_NAME} PUBLIC THOTH_IPC_NOTIFY_FD)
  # macOS default backend is libnotify (part of libSystem, no extra link).
  # THOTH_IPC_NOTIFY_FIFO forces the portable FIFO backend instead.
  if(THOTH_IPC_NOTIFY_FIFO)
    target_compile_definitions(${PROJECT_NAME} PUBLIC THOTH_IPC_NOTIFY_FIFO)
  endif()
endif()

# Opt-in Layer 2: thoth::async_recv() + reactor. PUBLIC (the templated sender API
# lives in the public header async_recv.h, so consumers compile against stdexec
# and the THOTH_IPC_STDEXEC switch).
if(THOTH_IPC_STDEXEC)
  target_link_libraries(${PROJECT_NAME} PUBLIC STDEXEC::stdexec)
  target_compile_definitions(${PROJECT_NAME} PUBLIC THOTH_IPC_STDEXEC)
endif()

target_link_libraries(${PROJECT_NAME} PUBLIC thoth_ipc_secure_crypto_c)

if(NOT MSVC)
  target_link_libraries(${PROJECT_NAME} PUBLIC
    $<$<NOT:$<STREQUAL:${CMAKE_SYSTEM_NAME},QNX>>:pthread>
    $<$<NOT:$<OR:$<STREQUAL:${CMAKE_SYSTEM_NAME},Windows>,$<STREQUAL:${CMAKE_SYSTEM_NAME},QNX>,$<STREQUAL:${CMAKE_SYSTEM_NAME},Darwin>>>:rt>)
endif()

# Opt-in C++20 named module `thoth.ipc` (see doc/modules.md). The interface
# unit re-exports the public surface of the headers; PUBLIC-linking thoth_ipc
# gives the module TU (and importers) the identical include dirs and PUBLIC
# compile definitions the headers were built with. CAUTION: if a PRIVATE
# compile definition ever gates a declaration in a *public* header, the module
# will diverge from the compiled library — keep such defines PUBLIC.
if(THOTH_IPC_BUILD_MODULES)
  add_library(thoth_ipc_module STATIC)
  target_sources(thoth_ipc_module
    PUBLIC
      FILE_SET CXX_MODULES
        BASE_DIRS ${THOTH_IPC_PROJECT_DIR}/modules
        FILES ${THOTH_IPC_PROJECT_DIR}/modules/thoth.ipc.cppm)
  target_link_libraries(thoth_ipc_module PUBLIC ${PROJECT_NAME})
  target_compile_features(thoth_ipc_module PUBLIC cxx_std_23)
  set_target_properties(thoth_ipc_module
    PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
endif()

install(
  TARGETS ${PROJECT_NAME}
  EXPORT thoth-ipc-targets
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib)

if(THOTH_IPC_BUILD_MODULES)
  # Ships the module *source* (thoth.ipc.cppm); no BMI is installed --
  # consumers of thoth-ipc::thoth_ipc_module recompile it (CMake >= 3.28).
  install(
    TARGETS thoth_ipc_module
    EXPORT thoth-ipc-targets
    ARCHIVE DESTINATION lib
    FILE_SET CXX_MODULES DESTINATION modules/thoth-ipc)
endif()

install(EXPORT thoth-ipc-targets
	FILE thoth-ipc-targets.cmake
	NAMESPACE thoth-ipc::
	DESTINATION share/thoth-ipc
	CXX_MODULES_DIRECTORY .
)

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/thoth-ipc-config.cmake.in"
[[include(CMakeFindDependencyMacro)
if("@THOTH_IPC_SECURE_OPENSSL@" STREQUAL "ON")
  find_dependency(OpenSSL REQUIRED COMPONENTS Crypto)
endif()
include("${CMAKE_CURRENT_LIST_DIR}/thoth-ipc-targets.cmake")
]])
configure_file("${CMAKE_CURRENT_BINARY_DIR}/thoth-ipc-config.cmake.in" "${CMAKE_CURRENT_BINARY_DIR}/thoth-ipc-config.cmake" @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/thoth-ipc-config.cmake DESTINATION share/thoth-ipc)

include(CMakePackageConfigHelpers)
write_basic_package_version_file(
	thothIpcConfigVersion.cmake
	VERSION ${PACKAGE_VERSION}
	COMPATIBILITY AnyNewerVersion
)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/thothIpcConfigVersion.cmake DESTINATION share/thoth-ipc)