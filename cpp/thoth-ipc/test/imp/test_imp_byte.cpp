
#include "../archive/test.h"

#include "thoth-ipc/imp/byte.h"
#include "thoth-ipc/imp/span.h"
#include "thoth-ipc/imp/detect_plat.h"

TEST(byte, construct) {
  {
    THOTH_IPC_UNUSED thoth::byte b;
    SUCCEED();
  }
  {
    thoth::byte b{};
    EXPECT_EQ(int(b), 0);
  }
  {
    thoth::byte b{123};
    EXPECT_EQ(int(b), 123);
  }
  {
    thoth::byte b{65535};
    EXPECT_EQ(int(b), 255);
    EXPECT_EQ(std::int8_t(b), -1);
  }
  {
    thoth::byte b{65536};
    EXPECT_EQ(int(b), 0);
  }
}

TEST(byte, compare) {
  {
    thoth::byte b1{}, b2{};
    EXPECT_EQ(b1, b2);
  }
  {
    thoth::byte b1{}, b2(321);
    EXPECT_NE(b1, b2);
  }
}

TEST(byte, byte_cast) {
  int a = 654321;
  int *pa = &a;

  // int * => byte *
  thoth::byte *pb = thoth::byte_cast(pa);
  EXPECT_EQ((std::size_t)pb, (std::size_t)pa);

  // byte * => int32_t *
  std::int32_t *pc = thoth::byte_cast<std::int32_t>(pb);
  EXPECT_EQ(*pc, a);

  // byte alignment check
  EXPECT_EQ(thoth::byte_cast<int>(pb + 1), nullptr);
}
