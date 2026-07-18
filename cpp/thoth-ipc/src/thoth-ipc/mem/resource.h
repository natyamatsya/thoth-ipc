#pragma once

#include <unordered_map>
#include <map>
#include <string>
#include <type_traits>
#include <utility>

#include "thoth-ipc/def.h"
#include "thoth-ipc/mem/container_allocator.h"

namespace thoth {

template <typename Key, typename T>
using unordered_map = std::unordered_map<
  Key, T, std::hash<Key>, std::equal_to<Key>, thoth::mem::container_allocator<std::pair<Key const, T>>
>;

template <typename Key, typename T>
using map = std::map<
  Key, T, std::less<Key>, thoth::mem::container_allocator<std::pair<Key const, T>>
>;

/// \brief Check string validity.
constexpr bool is_valid_string(char const *str) noexcept {
  return (str != nullptr) && (str[0] != '\0');
}

/// \brief Make a valid string.
inline std::string make_string(char const *str) {
  return is_valid_string(str) ? std::string{str} : std::string{};
}

namespace detail {
// Append one part of a public-ABI shm name: strings verbatim, integers in decimal
// (byte-identical to what the old fmt-based path produced).
inline void abi_name_append(std::string &out, char const *s) { if (s != nullptr) out += s; }
inline void abi_name_append(std::string &out, std::string const &s) { out += s; }
template <typename T, typename = std::enable_if_t<std::is_integral_v<std::decay_t<T>>>>
inline void abi_name_append(std::string &out, T v) { out += std::to_string(v); }
} // namespace detail

/// \brief Build a **public wire-ABI** shm object name:
/// `<prefix>__THOTH_SHM__<tag><args...>`. These names are part of the byte-exact
/// cross-language contract (see abi/abi.json `names[]`) — every port must produce
/// identical bytes for the same inputs. Header-only (plain std::string concat +
/// std::to_string for integers, no dependency on the `fmt` library) so tools like
/// abi/dump_abi.cpp can reuse it without linking.
template <typename A1, typename... A>
inline std::string make_public_abi_prefix(A1 &&prefix, A &&...args) {
  std::string out;
  detail::abi_name_append(out, std::forward<A1>(prefix));
  out += "__THOTH_SHM__";
  (detail::abi_name_append(out, std::forward<A>(args)), ...);
  return out;
}

} // namespace thoth
