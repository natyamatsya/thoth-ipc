#include "thoth-ipc/buffer.h"
#include "thoth-ipc/utility/pimpl.h"

#include <cstring>

namespace thoth {

bool operator==(buffer const & b1, buffer const & b2) {
    return (b1.size() == b2.size()) && (std::memcmp(b1.data(), b2.data(), b1.size()) == 0);
}

bool operator!=(buffer const & b1, buffer const & b2) {
    return !(b1 == b2);
}

class buffer::buffer_ : public pimpl<buffer_> {
public:
    void*       p_;
    std::size_t s_;
    void*       a_;
    buffer::destructor_t d_;

    buffer_(void* p, std::size_t s, buffer::destructor_t d, void* a)
        : p_(p), s_(s), a_(a), d_(d) {
    }

    ~buffer_() {
        if (d_ == nullptr) return;
        d_((a_ == nullptr) ? p_ : a_, s_);
    }
};

buffer::buffer()
    : buffer(nullptr, 0, nullptr, nullptr) {
}

buffer::buffer(void* p, std::size_t s, destructor_t d)
    : p_(p_->make(p, s, d, nullptr)) {
}

buffer::buffer(void* p, std::size_t s, destructor_t d, void* mem_to_free)
    : p_(p_->make(p, s, d, mem_to_free)) {
}

buffer::buffer(void* p, std::size_t s)
    : buffer(p, s, nullptr) {
}

buffer::buffer(char & c)
    : buffer(&c, 1) {
}

// Steal the pimpl and leave rhs empty (p_ == nullptr). This makes the move
// non-allocating and therefore noexcept — required so thoth::buffer can flow
// through senders/receivers value completions (which must be noexcept) and
// noexcept-move std containers. The moved-from buffer is valid: it destroys
// cleanly and queries as empty (guards below).
buffer::buffer(buffer&& rhs) noexcept
    : p_(rhs.p_) {
    rhs.p_ = nullptr;
}

buffer::~buffer() {
    if (p_ != nullptr) p_->clear();
}

void buffer::swap(buffer& rhs) {
    std::swap(p_, rhs.p_);
}

buffer& buffer::operator=(buffer rhs) {
    swap(rhs);
    return *this;
}

bool buffer::empty() const noexcept {
    return (p_ == nullptr) || (impl(p_)->p_ == nullptr) || (impl(p_)->s_ == 0);
}

void* buffer::data() noexcept {
    return (p_ == nullptr) ? nullptr : impl(p_)->p_;
}

void const * buffer::data() const noexcept {
    return (p_ == nullptr) ? nullptr : impl(p_)->p_;
}

std::size_t buffer::size() const noexcept {
    return (p_ == nullptr) ? 0 : impl(p_)->s_;
}

} // namespace thoth
