// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)

/**
 * \file thoth-ipc/nameof.h
 * \author mutouyun (orz@orzz.org)
 * \brief Gets the name string of a type.
 */
#pragma once

#include <typeinfo>
#include <string>
#include <cstring>

#include "thoth-ipc/imp/export.h"
#include "thoth-ipc/imp/span.h"
#include "thoth-ipc/imp/detect_plat.h"

namespace ipc {

/**
 * \brief The conventional way to obtain demangled symbol name.
 * \see https://www.boost.org/doc/libs/1_80_0/libs/core/doc/html/core/demangle.html
 * 
 * \param name the mangled name
 * \return std::string a human-readable demangled type name
 */
THOTH_IPC_EXPORT std::string demangle(std::string name) noexcept;

/**
 * \brief Returns an implementation defined string containing the name of the type.
 * \see https://en.cppreference.com/w/cpp/types/type_info/name
 * 
 * \tparam T a type
 * \return std::string a human-readable demangled type name
 */
template <typename T>
std::string nameof() noexcept {
  THOTH_IPC_TRY {
    return demangle(typeid(T).name());
  } THOTH_IPC_CATCH(...) {
    return {};
  }
}

} // namespace ipc
