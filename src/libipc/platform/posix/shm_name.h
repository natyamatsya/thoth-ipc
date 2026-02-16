#pragma once

#include <string>
#include <cstdint>
#include <cstring>

namespace ipc {
namespace posix_ {
namespace detail {

/// \brief FNV-1a 64-bit hash — simple, fast, no dependencies.
inline std::uint64_t fnv1a_64(const char *data, std::size_t len) noexcept {
    std::uint64_t hash = 0xcbf29ce484222325ULL;
    for (std::size_t i = 0; i < len; ++i) {
        hash ^= static_cast<std::uint64_t>(static_cast<unsigned char>(data[i]));
        hash *= 0x100000001b3ULL;
    }
    return hash;
}

/// \brief Convert a 64-bit value to a fixed-width 16-char lowercase hex string.
inline void to_hex(std::uint64_t val, char *buf) noexcept {
    static constexpr char digits[] = "0123456789abcdef";
    for (int i = 15; i >= 0; --i) {
        buf[i] = digits[val & 0xf];
        val >>= 4;
    }
}

/// \brief Produce a POSIX shm-safe name (with leading '/').
///
/// When LIBIPC_SHM_NAME_MAX is defined and > 0, names whose POSIX form
/// (including the leading '/') would exceed that limit are shortened to:
///     /<prefix>_<16-hex-FNV-1a-hash>
/// where <prefix> is a truncated portion of the original name for debuggability.
///
/// When LIBIPC_SHM_NAME_MAX is 0 or not defined, this is a simple '/' prefixer
/// that the compiler will inline and optimise away — zero cost.
inline std::string make_shm_name(const char *name) {
    std::string result;
    if (name[0] == '/')
        result = name;
    else
        result = std::string{"/"} + name;

#if defined(LIBIPC_SHM_NAME_MAX) && (LIBIPC_SHM_NAME_MAX > 0)
    constexpr std::size_t max_len = LIBIPC_SHM_NAME_MAX;
    // 1 (slash) + prefix + 1 (underscore) + 16 (hex hash) = 18 + prefix
    constexpr std::size_t hash_suffix_len = 1 + 16; // '_' + 16 hex chars
    constexpr std::size_t prefix_len = (max_len > hash_suffix_len + 1)
                                     ? (max_len - hash_suffix_len - 1) // -1 for leading '/'
                                     : 0;

    if (result.size() > max_len) {
        // Hash the FULL original name (before truncation) for uniqueness.
        std::uint64_t hash = fnv1a_64(result.data(), result.size());
        char hex[16];
        to_hex(hash, hex);

        std::string shortened;
        shortened.reserve(max_len);
        shortened += '/';
        if (prefix_len > 0)
            shortened.append(result, 1, prefix_len); // skip the leading '/' of original
        shortened += '_';
        shortened.append(hex, 16);
        result = std::move(shortened);
    }
#endif
    return result;
}

} // namespace detail
} // namespace posix_
} // namespace ipc
