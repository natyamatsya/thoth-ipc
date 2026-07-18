
#include "../archive/test.h"

#include "thoth-ipc/imp/system.h"

TEST(system, conf) {
  auto ret = thoth::sys::conf(thoth::sys::info::page_size);
  EXPECT_TRUE(ret);
  EXPECT_GE(ret.value(), 4096);
}
