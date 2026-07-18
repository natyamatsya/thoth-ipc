// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)

/**
 * \file thoth-ipc/export.h
 * \author mutouyun (orz@orzz.org)
 * \brief Define the symbol export interfaces.
 */
#pragma once

#include "thoth-ipc/imp/detect_plat.h"

#if defined(Q_DECL_EXPORT) && defined(Q_DECL_IMPORT)

# define THOTH_IPC_DECL_EXPORT Q_DECL_EXPORT
# define THOTH_IPC_DECL_IMPORT Q_DECL_IMPORT

#else // defined(Q_DECL_EXPORT) && defined(Q_DECL_IMPORT)

/**
 * \brief Compiler & system detection for THOTH_IPC_DECL_EXPORT & THOTH_IPC_DECL_IMPORT.
 * Not using QtCore cause it shouldn't depend on Qt.
 */
# if defined(THOTH_IPC_CC_MSVC) || defined(THOTH_IPC_OS_WIN)
#   define THOTH_IPC_DECL_EXPORT __declspec(dllexport)
#   define THOTH_IPC_DECL_IMPORT __declspec(dllimport)
# elif defined(THOTH_IPC_OS_ANDROID) || defined(THOTH_IPC_OS_LINUX) || defined(THOTH_IPC_CC_GNUC)
#   define THOTH_IPC_DECL_EXPORT __attribute__((visibility("default")))
#   define THOTH_IPC_DECL_IMPORT __attribute__((visibility("default")))
# else
#   define THOTH_IPC_DECL_EXPORT __attribute__((visibility("default")))
#   define THOTH_IPC_DECL_IMPORT __attribute__((visibility("default")))
# endif

#endif // defined(Q_DECL_EXPORT) && defined(Q_DECL_IMPORT)

/**
 * \brief Define THOTH_IPC_EXPORT for exporting function & class.
 */
#ifndef THOTH_IPC_EXPORT
# if defined(THOTH_IPC_LIBRARY_SHARED_BUILDING__)
#   define THOTH_IPC_EXPORT THOTH_IPC_DECL_EXPORT
# elif defined(THOTH_IPC_LIBRARY_SHARED_USING__)
#   define THOTH_IPC_EXPORT THOTH_IPC_DECL_IMPORT
# else
#   define THOTH_IPC_EXPORT
# endif
#endif /*THOTH_IPC_EXPORT*/
