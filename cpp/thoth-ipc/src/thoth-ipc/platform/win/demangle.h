// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)

/**
 * \file thoth-ipc/platform/win/demangle.h
 * \author mutouyun (orz@orzz.org)
 */
#pragma once

#include "thoth-ipc/imp/nameof.h"

namespace thoth {

std::string demangle(std::string name) noexcept {
  return std::move(name);
}

} // namespace thoth
