// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)

/**
 * \file thoth-ipc/platform/gnuc/demangle.h
 * \author mutouyun (orz@orzz.org)
 */
#pragma once

#include <cxxabi.h> // abi::__cxa_demangle
#include <cstdlib>  // std::malloc

#include "thoth-ipc/imp/nameof.h"
#include "thoth-ipc/imp/scope_exit.h"
#include "thoth-ipc/imp/detect_plat.h"

namespace thoth {

/**
 * \brief The conventional way to obtain demangled symbol name.
 * \see https://www.boost.org/doc/libs/1_80_0/libs/core/doc/html/core/demangle.html
 * 
 * \param name the mangled name
 * \return std::string a human-readable demangled type name
 */
std::string demangle(std::string name) noexcept {
  /// \see https://gcc.gnu.org/onlinedocs/libstdc++/libstdc++-html-USERS-4.3/a01696.html
  std::size_t sz = name.size() + 1;
  char *buffer = static_cast<char *>(std::malloc(sz));
  int status = 0;
  char *realname = abi::__cxa_demangle(name.data(), buffer, &sz, &status);
  if (realname == nullptr) {
    std::free(buffer);
    return {};
  }
  THOTH_IPC_SCOPE_EXIT(guard) = [realname] {
    std::free(realname);
  };
  THOTH_IPC_TRY {
    return std::move(name.assign(realname, sz));
  } THOTH_IPC_CATCH(...) {
    return {};
  }
}

} // namespace thoth
