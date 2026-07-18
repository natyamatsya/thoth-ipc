
#include <sstream>
#include <cstdint>

#include "../archive/test.h"

#include "thoth-ipc/imp/result.h"

TEST(result, ok) {
  thoth::result<std::uint64_t> ret;
  EXPECT_FALSE(ret);
  EXPECT_FALSE(ret.ok());
  EXPECT_EQ(ret.value(), 0);

  ret = {0};
  EXPECT_TRUE(ret);
  EXPECT_TRUE(ret.ok());
  EXPECT_EQ(ret.value(), 0);

  ret = thoth::result<std::uint64_t>(1234);
  EXPECT_TRUE(ret);
  EXPECT_TRUE(ret.ok());
  EXPECT_EQ(ret.value(), 1234);

  ret = std::error_code{9999, std::generic_category()};
  EXPECT_FALSE(ret);
  EXPECT_FALSE(ret.ok());
  EXPECT_EQ(ret.value(), 0);

  ret = 4321;
  EXPECT_TRUE(ret);
  EXPECT_TRUE(ret.ok());
  EXPECT_EQ(ret.value(), 4321);

  thoth::result<void> r1;
  EXPECT_FALSE(r1);
  r1 = std::error_code{};
  EXPECT_TRUE(r1);
  r1 = {};
  EXPECT_FALSE(r1);
  r1 = std::error_code{9999, std::generic_category()};
  EXPECT_FALSE(r1);
  EXPECT_EQ(r1.error().value(), 9999);

  thoth::result<int *> r2 {nullptr, std::error_code{4321, std::generic_category()}};
  EXPECT_NE(r2, nullptr); // thoth::result<int *>{nullptr}
  EXPECT_EQ(*r2, nullptr);
  EXPECT_FALSE(r2);
}

TEST(result, compare) {
  thoth::result<std::uint64_t> r1, r2;
  EXPECT_EQ(r1, r2);

  thoth::result<std::uint64_t> r3(0);
  EXPECT_NE(r1, r3);

  thoth::result<std::uint64_t> r4(222222);
  EXPECT_NE(r3, r4);

  thoth::result<std::uint64_t> r5(std::error_code{9999, std::generic_category()});
  EXPECT_NE(r4, r5);
  EXPECT_NE(r3, r5);

  r3 = r5;
  EXPECT_EQ(r3, r5);
}
