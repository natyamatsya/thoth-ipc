// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)

/**
 * \file thoth-ipc/error.h
 * \author mutouyun (orz@orzz.org)
 * \brief A platform-dependent error code.
 */
#pragma once

#include <system_error>
#include <string>
#include <cstdint>

#include "thoth-ipc/imp/export.h"
#include "thoth-ipc/imp/fmt_cpo.h"

namespace thoth {

/**
 * \brief Custom defined fmt_to method for imp::fmt
 */
namespace detail_tag_invoke {

inline bool tag_invoke(decltype(thoth::fmt_to), fmt_context &ctx, std::error_code const &ec) noexcept {
  return fmt_to(ctx, '[', ec.value(), ": ", ec.message(), ']');
}

} // namespace detail_tag_invoke
} // namespace thoth
