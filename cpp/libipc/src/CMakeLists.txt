project(ipc)

set (PACKAGE_VERSION 0.1.0)

aux_source_directory(${LIBIPC_PROJECT_DIR}/src/libipc SRC_FILES)
aux_source_directory(${LIBIPC_PROJECT_DIR}/src/libipc/sync SRC_FILES)
aux_source_directory(${LIBIPC_PROJECT_DIR}/src/libipc/platform SRC_FILES)
aux_source_directory(${LIBIPC_PROJECT_DIR}/src/libipc/imp SRC_FILES)
aux_source_directory(${LIBIPC_PROJECT_DIR}/src/libipc/mem SRC_FILES)
# execution/reactor.cpp compiles to an empty TU unless LIBIPC_STDEXEC is set.
aux_source_directory(${LIBIPC_PROJECT_DIR}/src/libipc/execution SRC_FILES)

file(GLOB HEAD_FILES
  ${LIBIPC_PROJECT_DIR}/include/libipc/*.h
  ${LIBIPC_PROJECT_DIR}/src/libipc/*.h
  ${LIBIPC_PROJECT_DIR}/src/libipc/*.inc
  ${LIBIPC_PROJECT_DIR}/src/libipc/circ/*.h
  ${LIBIPC_PROJECT_DIR}/src/libipc/memory/*.h
  ${LIBIPC_PROJECT_DIR}/src/libipc/platform/*.h
  ${LIBIPC_PROJECT_DIR}/src/libipc/utility/*.h)

if (LIBIPC_BUILD_SHARED_LIBS)
  add_library(${PROJECT_NAME} SHARED ${SRC_FILES} ${HEAD_FILES})
  target_compile_definitions(${PROJECT_NAME}
    INTERFACE
      LIBIPC_LIBRARY_SHARED_USING__
    PRIVATE
      LIBIPC_LIBRARY_SHARED_BUILDING__)
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
    "$<BUILD_INTERFACE:${LIBIPC_PROJECT_DIR}/include>"
    "$<INSTALL_INTERFACE:include>"
  PRIVATE ${LIBIPC_PROJECT_DIR}/src
          $<$<BOOL:UNIX>:${LIBIPC_PROJECT_DIR}/src/libipc/platform/linux>)

# The Linux platform code uses clockid_t and CLOCK_BOOTTIME/MONOTONIC/REALTIME.
# glibc only exposes clockid_t/CLOCK_* under the right feature-test macro when
# compiling as strict ISO C (-std=c17), and CLOCK_BOOTTIME specifically requires
# _GNU_SOURCE. (macOS exposes them unconditionally, so this is Linux-only.)
if(UNIX AND NOT APPLE)
  target_compile_definitions(${PROJECT_NAME} PRIVATE _GNU_SOURCE)
endif()

if(LIBIPC_SHM_NAME_MAX GREATER 0)
  target_compile_definitions(${PROJECT_NAME} PRIVATE LIBIPC_SHM_NAME_MAX=${LIBIPC_SHM_NAME_MAX})
endif()

if(WIN32)
  # Windows named-object namespace prefix (see top-level LIBIPC_WIN_OBJ_NAMESPACE).
  # PUBLIC so downstream TUs building notify/event names agree with the library.
  target_compile_definitions(${PROJECT_NAME} PUBLIC LIBIPC_WIN_OBJ_NS="${LIBIPC_WIN_OBJ_NAMESPACE}")
endif()

if(LIBIPC_USE_FILE_SHM)
  target_compile_definitions(${PROJECT_NAME} PRIVATE LIBIPC_USE_FILE_SHM)
endif()

if(APPLE AND LIBIPC_APPLE_APP_STORE_SAFE)
  target_compile_definitions(${PROJECT_NAME} PUBLIC LIBIPC_APPLE_APP_STORE_SAFE)
endif()

# Opt-in Layer 1 readiness handle (see notify.h). The public ABI
# (native_wait_handle) is stable regardless; the macro is PUBLIC so downstream
# TUs can feature-test it (#if defined(LIBIPC_NOTIFY_FD)) before relying on a
# functional handle. When OFF, native_wait_handle returns ipc::invalid_wait_handle.
if(LIBIPC_NOTIFY_FD)
  # Windows uses the named-Event backend (notify.h LIBIPC_NOTIFY_BACKEND_WINEVENT);
  # POSIX uses libnotify (Apple) or the FIFO backend. All are wired below.
  target_compile_definitions(${PROJECT_NAME} PUBLIC LIBIPC_NOTIFY_FD)
  # macOS default backend is libnotify (part of libSystem, no extra link).
  # LIBIPC_NOTIFY_FIFO forces the portable FIFO backend instead.
  if(LIBIPC_NOTIFY_FIFO)
    target_compile_definitions(${PROJECT_NAME} PUBLIC LIBIPC_NOTIFY_FIFO)
  endif()
endif()

# Opt-in Layer 2: ipc::async_recv() + reactor. PUBLIC (the templated sender API
# lives in the public header async_recv.h, so consumers compile against stdexec
# and the LIBIPC_STDEXEC switch).
if(LIBIPC_STDEXEC)
  target_link_libraries(${PROJECT_NAME} PUBLIC STDEXEC::stdexec)
  target_compile_definitions(${PROJECT_NAME} PUBLIC LIBIPC_STDEXEC)
endif()

target_link_libraries(${PROJECT_NAME} PUBLIC libipc_secure_crypto_c)

if(NOT MSVC)
  target_link_libraries(${PROJECT_NAME} PUBLIC
    $<$<NOT:$<STREQUAL:${CMAKE_SYSTEM_NAME},QNX>>:pthread>
    $<$<NOT:$<OR:$<STREQUAL:${CMAKE_SYSTEM_NAME},Windows>,$<STREQUAL:${CMAKE_SYSTEM_NAME},QNX>,$<STREQUAL:${CMAKE_SYSTEM_NAME},Darwin>>>:rt>)
endif()

install(
  TARGETS ${PROJECT_NAME}
  EXPORT thoth-ipc-targets
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib)

install(EXPORT thoth-ipc-targets
	FILE thoth-ipc-targets.cmake
	NAMESPACE thoth-ipc::
	DESTINATION share/thoth-ipc
)

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/thoth-ipc-config.cmake.in"
[[include(CMakeFindDependencyMacro)
if("@LIBIPC_SECURE_OPENSSL@" STREQUAL "ON")
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