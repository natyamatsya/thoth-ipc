// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <gtest/gtest.h>

#include "libipc/sync/sync_abi.h"

namespace sync_abi = ipc::detail::sync_abi;

namespace {

void write_expected_stamp(sync_abi::stamp_t *stamp, sync_abi::expected_t const &expected) {
    stamp->abi_version_major.store(expected.abi_version_major, std::memory_order_relaxed);
    stamp->abi_version_minor.store(expected.abi_version_minor, std::memory_order_relaxed);
    stamp->backend_id.store(expected.backend_id, std::memory_order_relaxed);
    stamp->primitive_id.store(expected.primitive_id, std::memory_order_relaxed);
    stamp->payload_size.store(expected.payload_size, std::memory_order_relaxed);
    stamp->magic.store(sync_abi::sync_abi_magic, std::memory_order_release);
}

} // namespace

TEST(SyncAbiGuard, InitOrValidateTimesOutOnStuckInit) {
    sync_abi::stamp_t stamp{};
    stamp.magic.store(sync_abi::sync_abi_init_in_progress, std::memory_order_release);

    auto const expected = sync_abi::expected_of(sync_abi::primitive_kind::mutex);
    EXPECT_FALSE(sync_abi::init_or_validate(&stamp, expected, sync_abi::primitive_kind::mutex));
}

TEST(SyncAbiGuard, InitOrValidateRejectsBackendMismatch) {
    sync_abi::stamp_t stamp{};
    auto const expected = sync_abi::expected_of(sync_abi::primitive_kind::condition);

    write_expected_stamp(&stamp, expected);
    stamp.backend_id.store(expected.backend_id + 1u, std::memory_order_release);

    EXPECT_FALSE(sync_abi::init_or_validate(&stamp, expected, sync_abi::primitive_kind::condition));
}

TEST(SyncAbiGuard, InitOrValidateInitializesEmptyStamp) {
    sync_abi::stamp_t stamp{};
    auto const expected = sync_abi::expected_of(sync_abi::primitive_kind::mutex);

    ASSERT_TRUE(sync_abi::init_or_validate(&stamp, expected, sync_abi::primitive_kind::mutex));
    EXPECT_EQ(stamp.magic.load(std::memory_order_acquire), sync_abi::sync_abi_magic);
    EXPECT_EQ(stamp.abi_version_major.load(std::memory_order_acquire), expected.abi_version_major);
    EXPECT_EQ(stamp.abi_version_minor.load(std::memory_order_acquire), expected.abi_version_minor);
    EXPECT_EQ(stamp.backend_id.load(std::memory_order_acquire), expected.backend_id);
    EXPECT_EQ(stamp.primitive_id.load(std::memory_order_acquire), expected.primitive_id);
    EXPECT_EQ(stamp.payload_size.load(std::memory_order_acquire), expected.payload_size);
}
