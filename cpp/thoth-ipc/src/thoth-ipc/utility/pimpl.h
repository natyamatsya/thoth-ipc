#pragma once

#include <new>
#include <utility>

#include "thoth-ipc/platform/detail.h"
#include "thoth-ipc/utility/concept.h"
#include "thoth-ipc/mem/new.h"

namespace thoth {

// pimpl small object optimization helpers

template <typename T, typename R = T*>
using IsImplComfortable = thoth::require<(sizeof(T) <= sizeof(T*)), R>;

template <typename T, typename R = T*>
using IsImplUncomfortable = thoth::require<(sizeof(T) > sizeof(T*)), R>;

template <typename T, typename... P>
THOTH_IPC_CONSTEXPR_ auto make_impl(P&&... params) -> IsImplComfortable<T> {
    T* buf {};
    ::new (&buf) T { std::forward<P>(params)... };
    return buf;
}

template <typename T>
THOTH_IPC_CONSTEXPR_ auto impl(T* const (& p)) -> IsImplComfortable<T> {
    return reinterpret_cast<T*>(&const_cast<char &>(reinterpret_cast<char const &>(p)));
}

template <typename T>
THOTH_IPC_CONSTEXPR_ auto clear_impl(T* p) -> IsImplComfortable<T, void> {
    if (p != nullptr) impl(p)->~T();
}

template <typename T, typename... P>
THOTH_IPC_CONSTEXPR_ auto make_impl(P&&... params) -> IsImplUncomfortable<T> {
    return mem::$new<T>(std::forward<P>(params)...);
}

template <typename T>
THOTH_IPC_CONSTEXPR_ auto clear_impl(T* p) -> IsImplUncomfortable<T, void> {
    mem::$delete(p);
}

template <typename T>
THOTH_IPC_CONSTEXPR_ auto impl(T* const (& p)) -> IsImplUncomfortable<T> {
    return p;
}

template <typename T>
struct pimpl {
    template <typename... P>
    THOTH_IPC_CONSTEXPR_ static T* make(P&&... params) {
        return make_impl<T>(std::forward<P>(params)...);
    }

    THOTH_IPC_CONSTEXPR_ void clear() {
        clear_impl(static_cast<T*>(const_cast<pimpl*>(this)));
    }
};

} // namespace thoth
