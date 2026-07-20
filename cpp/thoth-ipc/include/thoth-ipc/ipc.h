#pragma once

#include <string>

#include "thoth-ipc/imp/export.h"
#include "thoth-ipc/imp/detect_plat.h"
#include "thoth-ipc/def.h"
#include "thoth-ipc/buffer.h"
#include "thoth-ipc/shm.h"

namespace thoth {

using handle_t = void*;
using buff_t   = buffer;

/**
 * \brief Native waitable handle for a channel's readiness (opt-in Layer 1).
 *
 * When libipc is built with THOTH_IPC_NOTIFY_FD, a receiver channel exposes a
 * kernel object, signalled whenever a message is enqueued for it, that a
 * consumer can register with its own reactor (epoll / kqueue / Qt
 * QSocketNotifier / WaitForMultipleObjects) instead of dedicating a blocking
 * thread to recv(). On POSIX this is a file descriptor; on Windows a HANDLE.
 *
 * See context/stdexec-async-recv-rfc.md.
 */
#if defined(THOTH_IPC_OS_WIN)
using wait_handle_t = void*; // HANDLE
inline wait_handle_t const invalid_wait_handle = nullptr;
#else
using wait_handle_t = int;   // file descriptor
inline constexpr wait_handle_t invalid_wait_handle = -1;
#endif

// Named (rather than anonymous) so the enumerators have external linkage and
// can be re-exported by the thoth.ipc module (modules/thoth.ipc.cppm).
enum connect_mode : unsigned {
    sender,
    receiver
};

template <typename Flag>
struct THOTH_IPC_EXPORT chan_impl {
    static thoth::handle_t init_first();

    static bool connect   (thoth::handle_t * ph, char const * name, unsigned mode);
    static bool connect   (thoth::handle_t * ph, prefix, char const * name, unsigned mode);
    static bool reconnect (thoth::handle_t * ph, unsigned mode);
    static void disconnect(thoth::handle_t h);
    static void destroy   (thoth::handle_t h);

    static char const * name(thoth::handle_t h);

    // Release memory without waiting for the connection to disconnect.
    static void release(thoth::handle_t h) noexcept;

    // Force cleanup of all shared memory storage that handles depend on.
    static void clear(thoth::handle_t h) noexcept;
    static void clear_storage(char const * name) noexcept;
    static void clear_storage(prefix, char const * name) noexcept;

    static std::size_t recv_count   (thoth::handle_t h);
    static bool        wait_for_recv(thoth::handle_t h, std::size_t r_count, std::uint64_t tm);

    static bool   send(thoth::handle_t h, void const * data, std::size_t size, std::uint64_t tm);
    static buff_t recv(thoth::handle_t h, std::uint64_t tm);

    static bool   try_send(thoth::handle_t h, void const * data, std::size_t size, std::uint64_t tm);
    static buff_t try_recv(thoth::handle_t h);

    // Opt-in Layer 1: readiness handle for this (receiver) channel. Returns
    // thoth::invalid_wait_handle unless libipc was built with THOTH_IPC_NOTIFY_FD and
    // the handle is connected as a receiver.
    static wait_handle_t native_wait_handle(thoth::handle_t h) noexcept;
};

template <typename Flag>
class chan_wrapper {
private:
    using detail_t = chan_impl<Flag>;

    thoth::handle_t h_ = detail_t::init_first();
    unsigned mode_   = thoth::sender;
    bool connected_  = false;

public:
    chan_wrapper() noexcept = default;

    explicit chan_wrapper(char const * name, unsigned mode = thoth::sender)
        : connected_{this->connect(name, mode)} {
    }

    chan_wrapper(prefix pref, char const * name, unsigned mode = thoth::sender)
        : connected_{this->connect(pref, name, mode)} {
    }

    chan_wrapper(chan_wrapper&& rhs) noexcept
        : chan_wrapper{} {
        swap(rhs);
    }

    ~chan_wrapper() {
        detail_t::destroy(h_);
    }

    void swap(chan_wrapper& rhs) noexcept {
        std::swap(h_        , rhs.h_);
        std::swap(mode_     , rhs.mode_);
        std::swap(connected_, rhs.connected_);
    }

    chan_wrapper& operator=(chan_wrapper rhs) noexcept {
        swap(rhs);
        return *this;
    }

    char const * name() const noexcept {
        return detail_t::name(h_);
    }

    // Release memory without waiting for the connection to disconnect.
    void release() noexcept {
        detail_t::release(h_);
        h_ = nullptr;
    }

    // Clear shared memory files under opened handle.
    void clear() noexcept {
        detail_t::clear(h_);
        h_ = nullptr;
    }

    // Clear shared memory files under a specific name.
    static void clear_storage(char const * name) noexcept {
        detail_t::clear_storage(name);
    }

    // Clear shared memory files under a specific name with a prefix.
    static void clear_storage(prefix pref, char const * name) noexcept {
        detail_t::clear_storage(pref, name);
    }

    thoth::handle_t handle() const noexcept {
        return h_;
    }

    bool valid() const noexcept {
        return (handle() != nullptr);
    }

    unsigned mode() const noexcept {
        return mode_;
    }

    chan_wrapper clone() const {
        return chan_wrapper { name(), mode_ };
    }

    /**
     * Building handle, then try connecting with name & mode flags.
    */
    bool connect(char const * name, unsigned mode = thoth::sender | thoth::receiver) {
        if (name == nullptr || name[0] == '\0') return false;
        detail_t::disconnect(h_); // clear old connection
        return connected_ = detail_t::connect(&h_, name, mode_ = mode);
    }
    bool connect(prefix pref, char const * name, unsigned mode = thoth::sender | thoth::receiver) {
        if (name == nullptr || name[0] == '\0') return false;
        detail_t::disconnect(h_); // clear old connection
        return connected_ = detail_t::connect(&h_, pref, name, mode_ = mode);
    }

    /**
     * Try connecting with new mode flags.
    */
    bool reconnect(unsigned mode) {
        if (!valid()) return false;
        if (connected_ && (mode_ == mode)) return true;
        return connected_ = detail_t::reconnect(&h_, mode_ = mode);
    }

    void disconnect() {
        if (!valid()) return;
        detail_t::disconnect(h_);
        connected_ = false;
    }

    std::size_t recv_count() const {
        return detail_t::recv_count(h_);
    }

    bool wait_for_recv(std::size_t r_count, std::uint64_t tm = invalid_value) const {
        return detail_t::wait_for_recv(h_, r_count, tm);
    }

    static bool wait_for_recv(char const * name, std::size_t r_count, std::uint64_t tm = invalid_value) {
        return chan_wrapper(name).wait_for_recv(r_count, tm);
    }

    /**
     * If timeout, this function would call 'force_push' to send the data forcibly.
    */
    bool send(void const * data, std::size_t size, std::uint64_t tm = default_timeout) {
        return detail_t::send(h_, data, size, tm);
    }
    bool send(buff_t const & buff, std::uint64_t tm = default_timeout) {
        return this->send(buff.data(), buff.size(), tm);
    }
    bool send(std::string const & str, std::uint64_t tm = default_timeout) {
        return this->send(str.c_str(), str.size() + 1, tm);
    }

    /**
     * If timeout, this function would just return false.
    */
    bool try_send(void const * data, std::size_t size, std::uint64_t tm = default_timeout) {
        return detail_t::try_send(h_, data, size, tm);
    }
    bool try_send(buff_t const & buff, std::uint64_t tm = default_timeout) {
        return this->try_send(buff.data(), buff.size(), tm);
    }
    bool try_send(std::string const & str, std::uint64_t tm = default_timeout) {
        return this->try_send(str.c_str(), str.size() + 1, tm);
    }

    buff_t recv(std::uint64_t tm = invalid_value) {
        return detail_t::recv(h_, tm);
    }

    buff_t try_recv() {
        return detail_t::try_recv(h_);
    }

    /**
     * \brief Native readiness handle for this receiver channel (opt-in Layer 1).
     *
     * Signalled whenever a message is enqueued for this channel; register it
     * with a reactor (epoll / kqueue / QSocketNotifier / WaitForMultipleObjects)
     * to multiplex many channels on one thread instead of blocking in recv().
     * Returns thoth::invalid_wait_handle unless built with THOTH_IPC_NOTIFY_FD and
     * connected as a receiver. The handle is owned by this channel and stays
     * valid until disconnect/destruction — do not close it.
     */
    wait_handle_t native_wait_handle() const noexcept {
        return detail_t::native_wait_handle(h_);
    }
};

template <relat Rp, relat Rc, trans Ts>
using chan = chan_wrapper<thoth::wr<Rp, Rc, Ts>>;

/**
 * \class route
 *
 * \note You could use one producer/server/sender for sending messages to a route,
 *       then all the consumers/clients/receivers which are receiving with this route,
 *       would receive your sent messages.
 *       A route could only be used in 1 to N (one producer/writer to multi consumers/readers).
*/
using route = chan<relat::single, relat::multi, trans::broadcast>;

/**
 * \class channel
 *
 * \note You could use multi producers/writers for sending messages to a channel,
 *       then all the consumers/readers which are receiving with this channel,
 *       would receive your sent messages.
*/
using channel = chan<relat::multi, relat::multi, trans::broadcast>;

} // namespace thoth
