
#include "../archive/test.h"

#include <utility>

#include "thoth-ipc/mem/central_cache_pool.h"

TEST(central_cache_pool, ctor) {
  ASSERT_FALSE((std::is_default_constructible<thoth::mem::central_cache_pool<thoth::mem::block<1>, 1>>::value));
  ASSERT_FALSE((std::is_copy_constructible<thoth::mem::central_cache_pool<thoth::mem::block<1>, 1>>::value));
  ASSERT_FALSE((std::is_move_constructible<thoth::mem::central_cache_pool<thoth::mem::block<1>, 1>>::value));
  ASSERT_FALSE((std::is_copy_assignable<thoth::mem::central_cache_pool<thoth::mem::block<1>, 1>>::value));
  ASSERT_FALSE((std::is_move_assignable<thoth::mem::central_cache_pool<thoth::mem::block<1>, 1>>::value));
  {
    auto &pool = thoth::mem::central_cache_pool<thoth::mem::block<1024>, 1>::instance();
    thoth::mem::block<1024> *b1 = pool.aqueire();
    ASSERT_FALSE(nullptr == b1);
    EXPECT_TRUE (nullptr == b1->next);
    pool.release(b1);
    thoth::mem::block<1024> *b2 = pool.aqueire();
    EXPECT_EQ(b1, b2);
    thoth::mem::block<1024> *b3 = pool.aqueire();
    ASSERT_FALSE(nullptr == b3);
    EXPECT_TRUE (nullptr == b3->next);
    EXPECT_NE(b1, b3);
  }
  {
    auto &pool = thoth::mem::central_cache_pool<thoth::mem::block<1>, 2>::instance();
    thoth::mem::block<1> *b1 = pool.aqueire();
    ASSERT_FALSE(nullptr == b1);
    ASSERT_FALSE(nullptr == b1->next);
    EXPECT_TRUE (nullptr == b1->next->next);
    pool.release(b1);
    thoth::mem::block<1> *b2 = pool.aqueire();
    EXPECT_EQ(b1, b2);
    thoth::mem::block<1> *b3 = pool.aqueire();
    EXPECT_NE(b1, b3);
    thoth::mem::block<1> *b4 = pool.aqueire();
    ASSERT_FALSE(nullptr == b4);
    ASSERT_FALSE(nullptr == b4->next);
    EXPECT_TRUE (nullptr == b4->next->next);
    EXPECT_NE(b1, b4);
  }
}
