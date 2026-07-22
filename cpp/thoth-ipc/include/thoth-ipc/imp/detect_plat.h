// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

/**
 * \file thoth-ipc/detect_plat.h
 * \author mutouyun (orz@orzz.org)
 * \brief Define platform detection related interfaces.
 */
#pragma once

/// \brief OS check.

#if defined(WINCE) || defined(_WIN32_WCE)
# define THOTH_IPC_OS_WINCE
#elif defined(WIN64) || defined(_WIN64) || defined(__WIN64__) || \
     (defined(__x86_64) && defined(__MSYS__))
#define THOTH_IPC_OS_WIN64
#elif defined(WIN32) || defined(_WIN32) || defined(__WIN32__) || \
      defined(__NT__) || defined(__MSYS__)
# define THOTH_IPC_OS_WIN32
#elif defined(__FreeBSD__)
# define THOTH_IPC_OS_FREEBSD
#elif defined(__QNX__) || defined(__QNXNTO__)
# define THOTH_IPC_OS_QNX
#elif defined(__APPLE__)
# define THOTH_IPC_OS_APPLE
#elif defined(ANDROID) || defined(__ANDROID__)
# define THOTH_IPC_OS_ANDROID
#elif defined(__linux__) || defined(__linux)
# define THOTH_IPC_OS_LINUX
#elif defined(_POSIX_VERSION)
# define THOTH_IPC_OS_POSIX
#else
# error "This OS is unsupported."
#endif

#if defined(THOTH_IPC_OS_WIN32) || defined(THOTH_IPC_OS_WIN64) || \
    defined(THOTH_IPC_OS_WINCE)
# define THOTH_IPC_OS_WIN
#endif

/// \brief Compiler check.

#if defined(_MSC_VER)
# define THOTH_IPC_CC_MSVC      _MSC_VER
# define THOTH_IPC_CC_MSVC_2015 1900
# define THOTH_IPC_CC_MSVC_2017 1910
# define THOTH_IPC_CC_MSVC_2019 1920
# define THOTH_IPC_CC_MSVC_2022 1930
#elif defined(__GNUC__)
# define THOTH_IPC_CC_GNUC __GNUC__
# if defined(__clang__)
#   define THOTH_IPC_CC_CLANG
#endif
#else
# error "This compiler is unsupported."
#endif

/// \brief Instruction set.
/// \see https://sourceforge.net/p/predef/wiki/Architectures/

#if defined(_M_X64) || defined(_M_AMD64) || \
    defined(__x86_64__) || defined(__x86_64) || \
    defined(__amd64__) || defined(__amd64)
# define THOTH_IPC_INSTR_X64
#elif defined(_M_IA64) || defined(__IA64__) || defined(_IA64) || \
      defined(__ia64__) || defined(__ia64)
# define THOTH_IPC_INSTR_I64
#elif defined(_M_IX86) || defined(_X86_) || defined(__i386__) || defined(__i386)
# define THOTH_IPC_INSTR_X86
#elif defined(_M_ARM64) || defined(__arm64__) || defined(__aarch64__)
# define THOTH_IPC_INSTR_ARM64
#elif defined(_M_ARM) || defined(_ARM) || defined(__arm__) || defined(__arm)
# define THOTH_IPC_INSTR_ARM32
#else
# error "This instruction set is unsupported."
#endif

#if defined(THOTH_IPC_INSTR_X86) || defined(THOTH_IPC_INSTR_X64)
# define THOTH_IPC_INSTR_X86_64
#elif defined(THOTH_IPC_INSTR_ARM32) || defined(THOTH_IPC_INSTR_ARM64)
# define THOTH_IPC_INSTR_ARM
#endif

/// \brief Byte order.

#if defined(__BYTE_ORDER__)
# define THOTH_IPC_ENDIAN_BIG   (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
# define THOTH_IPC_ENDIAN_LIT   (!THOTH_IPC_ENDIAN_BIG)
#else
# define THOTH_IPC_ENDIAN_BIG   (0)
# define THOTH_IPC_ENDIAN_LIT   (1)
#endif

/// \brief C++ version.

// MSVC reports __cplusplus as 199711L unless the consumer passes /Zc:__cplusplus; _MSVC_LANG always
// reflects the /std: level. Consult it so the standard is detected correctly regardless of the
// consumer's flags (the bundled flatbuffers/gtest use the same idiom).
#if defined(_MSVC_LANG)
# define THOTH_IPC_CPLUSPLUS _MSVC_LANG
#else
# define THOTH_IPC_CPLUSPLUS __cplusplus
#endif

#if (THOTH_IPC_CPLUSPLUS >= 202002L) && !defined(THOTH_IPC_CPP_20)
# define THOTH_IPC_CPP_20
#endif
#if (THOTH_IPC_CPLUSPLUS >= 201703L) && !defined(THOTH_IPC_CPP_17)
# define THOTH_IPC_CPP_17
#endif
#if /*(__cplusplus >= 201402L) &&*/ !defined(THOTH_IPC_CPP_14)
# define THOTH_IPC_CPP_14
#endif

#if !defined(THOTH_IPC_CPP_20) && \
    !defined(THOTH_IPC_CPP_17) && \
    !defined(THOTH_IPC_CPP_14)
# error "This C++ version is unsupported."
#endif

/// \brief Feature cross-platform adaptation.

#if defined(THOTH_IPC_CPP_17)
# define THOTH_IPC_INLINE_CONSTEXPR inline constexpr
#else
# define THOTH_IPC_INLINE_CONSTEXPR constexpr
#endif

/// \brief C++ attributes.
/// \see https://en.cppreference.com/w/cpp/language/attributes

#if defined(__has_cpp_attribute)
# if __has_cpp_attribute(fallthrough)
#   define THOTH_IPC_FALLTHROUGH [[fallthrough]]
# endif
# if __has_cpp_attribute(maybe_unused)
#   define THOTH_IPC_UNUSED [[maybe_unused]]
# endif
# if __has_cpp_attribute(likely)
#   define THOTH_IPC_LIKELY(...) (__VA_ARGS__) [[likely]]
# endif
# if __has_cpp_attribute(unlikely)
#   define THOTH_IPC_UNLIKELY(...) (__VA_ARGS__) [[unlikely]]
# endif
# if __has_cpp_attribute(nodiscard)
#   define THOTH_IPC_NODISCARD [[nodiscard]]
# endif
# if __has_cpp_attribute(assume)
#   define THOTH_IPC_ASSUME(...) [[assume(__VA_ARGS__)]]
# endif
#endif

#if !defined(THOTH_IPC_FALLTHROUGH)
# if defined(THOTH_IPC_CC_GNUC)
#   define THOTH_IPC_FALLTHROUGH __attribute__((__fallthrough__))
# else
#   define THOTH_IPC_FALLTHROUGH
# endif
#endif

#if !defined(THOTH_IPC_UNUSED)
# if defined(THOTH_IPC_CC_GNUC)
#   define THOTH_IPC_UNUSED __attribute__((__unused__))
# elif defined(THOTH_IPC_CC_MSVC)
#   define THOTH_IPC_UNUSED __pragma(warning(suppress: 4100 4101 4189))
# else
#   define THOTH_IPC_UNUSED
# endif
#endif

#if !defined(THOTH_IPC_LIKELY)
# if defined(__has_builtin)
#   if __has_builtin(__builtin_expect)
#     define THOTH_IPC_LIKELY(...) (__builtin_expect(!!(__VA_ARGS__), 1))
#   endif
# endif
#endif

#if !defined(THOTH_IPC_LIKELY)
# define THOTH_IPC_LIKELY(...) (__VA_ARGS__)
#endif

#if !defined(THOTH_IPC_UNLIKELY)
# if defined(__has_builtin)
#   if __has_builtin(__builtin_expect)
#     define THOTH_IPC_UNLIKELY(...) (__builtin_expect(!!(__VA_ARGS__), 0))
#   endif
# endif
#endif

#if !defined(THOTH_IPC_UNLIKELY)
# define THOTH_IPC_UNLIKELY(...) (__VA_ARGS__)
#endif

#if !defined(THOTH_IPC_NODISCARD)
/// \see https://stackoverflow.com/questions/4226308/msvc-equivalent-of-attribute-warn-unused-result
# if defined(THOTH_IPC_CC_GNUC) && (THOTH_IPC_CC_GNUC >= 4)
#   define THOTH_IPC_NODISCARD __attribute__((warn_unused_result))
# elif defined(THOTH_IPC_CC_MSVC) && (THOTH_IPC_CC_MSVC >= 1700)
#   define THOTH_IPC_NODISCARD _Check_return_
# else
#   define THOTH_IPC_NODISCARD
# endif
#endif

#if !defined(THOTH_IPC_ASSUME)
# if defined(__has_builtin)
#   if __has_builtin(__builtin_assume)
      /// \see https://clang.llvm.org/docs/LanguageExtensions.html#langext-builtin-assume
#     define THOTH_IPC_ASSUME(...) __builtin_assume(__VA_ARGS__)
#   elif __has_builtin(__builtin_unreachable)
      /// \see https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html#index-_005f_005fbuiltin_005funreachable
#     define THOTH_IPC_ASSUME(...) do { if (!(__VA_ARGS__)) __builtin_unreachable(); } while (false)
#   endif
# endif
#endif

#if !defined(THOTH_IPC_ASSUME)
# if defined(THOTH_IPC_CC_MSVC)
    /// \see https://learn.microsoft.com/en-us/cpp/intrinsics/assume?view=msvc-140
#   define THOTH_IPC_ASSUME(...) __assume(__VA_ARGS__)
# else
#   define THOTH_IPC_ASSUME(...)
# endif
#endif

/// \see https://gcc.gnu.org/onlinedocs/libstdc++/manual/using_exceptions.html
///      https://learn.microsoft.com/en-us/cpp/preprocessor/predefined-macros
///      https://stackoverflow.com/questions/6487013/programmatically-determine-whether-exceptions-are-enabled
#if defined(__cpp_exceptions) && __cpp_exceptions || \
    defined(__EXCEPTIONS) || defined(_CPPUNWIND)
# define THOTH_IPC_TRY                    try
# define THOTH_IPC_CATCH(...)             catch (__VA_ARGS__)
# define THOTH_IPC_THROW($EXCEPTION, ...) throw $EXCEPTION
#else
# define THOTH_IPC_TRY                    if (true)
# define THOTH_IPC_CATCH(...)             else if (false)
# define THOTH_IPC_THROW($EXCEPTION, ...) return __VA_ARGS__
#endif
