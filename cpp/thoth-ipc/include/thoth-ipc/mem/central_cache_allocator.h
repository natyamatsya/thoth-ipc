// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)

/**
 * \file thoth-ipc/central_cache_allocator.h
 * \author mutouyun (orz@orzz.org)
 * \brief The central cache allocator getter.
 */
#pragma once

#include "thoth-ipc/imp/export.h"
#include "thoth-ipc/mem/bytes_allocator.h"

namespace ipc {
namespace mem {

/// \brief Get the central cache allocator.
/// \note The central cache allocator is used to allocate memory for the central cache pool.
///       The underlying memory resource is a `monotonic_buffer_resource` with a fixed-size buffer.
LIBIPC_EXPORT bytes_allocator &central_cache_allocator() noexcept;

} // namespace mem
} // namespace ipc
