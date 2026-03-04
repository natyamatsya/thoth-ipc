# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

cmake_minimum_required(VERSION 3.30)
project(libipc-secure-crypto-c LANGUAGES C)

option(SECURE_CRYPTO_C_OPENSSL
    "Enable OpenSSL EVP backend for the secure crypto C ABI."
    OFF)

add_library(libipc_secure_crypto_c STATIC
    src/secure_crypto_c.c
)

set_target_properties(libipc_secure_crypto_c PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

target_include_directories(libipc_secure_crypto_c
    PUBLIC
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>"
        "$<INSTALL_INTERFACE:include>"
)

if(SECURE_CRYPTO_C_OPENSSL)
    find_package(OpenSSL REQUIRED COMPONENTS Crypto)
    target_compile_definitions(libipc_secure_crypto_c PUBLIC LIBIPC_SECURE_OPENSSL)
    target_link_libraries(libipc_secure_crypto_c PUBLIC OpenSSL::Crypto)
endif()

add_library(libipc::secure_crypto_c ALIAS libipc_secure_crypto_c)

set(_secure_crypto_export_set "secure-crypto-c-targets")
set(_secure_crypto_emit_export_file ON)
if(DEFINED SECURE_CRYPTO_C_EXPORT_SET)
    set(_secure_crypto_export_set "${SECURE_CRYPTO_C_EXPORT_SET}")
    set(_secure_crypto_emit_export_file OFF)
endif()

install(TARGETS libipc_secure_crypto_c
    EXPORT ${_secure_crypto_export_set}
    ARCHIVE DESTINATION lib
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
)

install(DIRECTORY include/
    DESTINATION include
)

if(_secure_crypto_emit_export_file)
    install(EXPORT ${_secure_crypto_export_set}
        FILE secure-crypto-c-targets.cmake
        NAMESPACE libipc::
        DESTINATION share/secure-crypto-c
    )
endif()
