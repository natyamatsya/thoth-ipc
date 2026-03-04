// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <gtest/gtest.h>

#include "libipc/proto/codecs/protobuf_google_message_lite.h"

TEST(ProtobufGoogleMessageLiteAdapter, HeaderCompiles) {
#if __has_include(<google/protobuf/message_lite.h>)
    static_assert(ipc::proto::google_message_lite<::google::protobuf::MessageLite>);
#endif
    SUCCEED();
}
