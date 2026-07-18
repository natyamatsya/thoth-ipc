// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

#include <gtest/gtest.h>

#include "thoth-ipc/proto/codecs/protobuf_google_message_lite.h"

TEST(ProtobufGoogleMessageLiteAdapter, HeaderCompiles) {
#if __has_include(<google/protobuf/message_lite.h>)
    static_assert(thoth::proto::google_message_lite<::google::protobuf::MessageLite>);
#endif
    SUCCEED();
}
